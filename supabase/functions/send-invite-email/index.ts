import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const BASE62 = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

function randomInviteToken(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  let out = "";
  for (let i = 0; i < 32; i++) {
    out += BASE62[bytes[i]! % 62];
  }
  return out;
}

function normalizeEmail(raw: string): string | null {
  const s = raw.trim().toLowerCase();
  if (s.length === 0 || s.length > 320) return null;
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(s)) return null;
  return s;
}

function isInviteValid(inv: {
  is_active: boolean;
  uses: number;
  max_uses: number | null;
  expires_at: string | null;
}): boolean {
  if (!inv.is_active) return false;
  if (inv.max_uses != null && inv.uses >= inv.max_uses) return false;
  if (inv.expires_at != null && new Date(inv.expires_at) <= new Date()) return false;
  return true;
}

async function sendSendGridEmail(args: {
  apiKey: string;
  fromEmail: string;
  fromName: string;
  toEmail: string;
  subject: string;
  text: string;
  html: string;
}): Promise<{ ok: true } | { ok: false; message: string }> {
  const res = await fetch("https://api.sendgrid.com/v3/mail/send", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${args.apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      personalizations: [{ to: [{ email: args.toEmail }] }],
      from: { email: args.fromEmail, name: args.fromName },
      subject: args.subject,
      content: [
        { type: "text/plain", value: args.text },
        { type: "text/html", value: args.html },
      ],
    }),
  });
  if (res.ok || res.status === 202) {
    return { ok: true };
  }
  const errText = await res.text();
  console.error("[send-invite-email] SendGrid error:", res.status, errText);
  return { ok: false, message: "Could not send email" };
}

async function invokeSendNotification(args: {
  supabaseUrl: string;
  serviceRoleKey: string;
  userId: string;
  tripId: string;
  tripName: string;
  inviterLabel: string;
  resent: boolean;
}): Promise<void> {
  const idem = args.resent
    ? `trip_email_invite:${args.tripId}:${args.userId}:${Date.now()}`
    : `trip_email_invite:${args.tripId}:${args.userId}`;
  const res = await fetch(`${args.supabaseUrl}/functions/v1/send-notification`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${args.serviceRoleKey}`,
      apikey: args.serviceRoleKey,
    },
    body: JSON.stringify({
      userId: args.userId,
      type: "trip_email_invite",
      title: "Trip invite",
      body: `${args.inviterLabel} invited you to “${args.tripName}” in Wayfind.`,
      data: {
        trip_id: args.tripId,
        type: "trip_email_invite",
      },
      idempotencyKey: idem,
    }),
  });
  if (!res.ok) {
    const t = await res.text();
    console.error("[send-invite-email] send-notification failed:", res.status, t);
  }
}

interface RequestBody {
  trip_id?: string;
  email?: string;
  role?: string;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), {
      status: 405,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const sendgridKey = Deno.env.get("SENDGRID_API_KEY");
  const fromEmail = Deno.env.get("INVITE_FROM_EMAIL") ?? Deno.env.get("SENDGRID_FROM_EMAIL");
  const inviteBase = (Deno.env.get("INVITE_WEB_BASE_URL") ?? "https://wayfind.city/invite").replace(
    /\/$/,
    "",
  );

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(JSON.stringify({ error: "Missing authorization header" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });
    const {
      data: { user },
      error: userError,
    } = await userClient.auth.getUser();
    if (userError || !user) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const body = (await req.json()) as RequestBody;
    const tripId = typeof body.trip_id === "string" ? body.trip_id.trim() : "";
    const role = body.role === "viewer" ? "viewer" : body.role === "editor" ? "editor" : "";
    const normalizedEmail = typeof body.email === "string" ? normalizeEmail(body.email) : null;

    if (!tripId || !role || !normalizedEmail) {
      return new Response(
        JSON.stringify({ error: "trip_id, email, and role (editor|viewer) are required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const callerEmail = (user.email ?? "").trim().toLowerCase();
    if (callerEmail && callerEmail === normalizedEmail) {
      return new Response(JSON.stringify({ error: "You cannot invite your own email address" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const admin = createClient(supabaseUrl, serviceRoleKey);

    const { data: trip, error: tripErr } = await admin
      .from("trips")
      .select("id, name, user_id")
      .eq("id", tripId)
      .maybeSingle();

    if (tripErr || !trip) {
      return new Response(JSON.stringify({ error: "Trip not found" }), {
        status: 404,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    if (trip.user_id !== user.id) {
      return new Response(JSON.stringify({ error: "Only the trip owner can send email invites" }), {
        status: 403,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const tripName = typeof trip.name === "string" && trip.name.trim() ? trip.name.trim() : "a trip";

    const { data: inviterProfile } = await admin
      .from("profiles")
      .select("display_name")
      .eq("id", user.id)
      .maybeSingle();
    const inviterName =
      (inviterProfile?.display_name as string | undefined)?.trim() || user.email?.split("@")[0] || "Someone";
    const inviterLabel = inviterName;

    const { data: inviteeId, error: lookupErr } = await admin.rpc("lookup_auth_user_id_by_email", {
      p_email: normalizedEmail,
    });

    if (lookupErr) {
      console.error("[send-invite-email] lookup error:", lookupErr);
      return new Response(JSON.stringify({ error: "Could not look up recipient" }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const inviteeUserId = typeof inviteeId === "string" ? inviteeId : null;

    const { count: acceptedCount, error: countErr } = await admin
      .from("trip_collaborators")
      .select("id", { count: "exact", head: true })
      .eq("trip_id", tripId)
      .eq("status", "accepted");

    if (countErr) {
      console.error("[send-invite-email] count error:", countErr);
      return new Response(JSON.stringify({ error: "Could not verify collaborator limit" }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    if ((acceptedCount ?? 0) >= 25) {
      return new Response(JSON.stringify({ error: "This trip has reached the collaborator limit" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    if (inviteeUserId) {
      if (inviteeUserId === trip.user_id) {
        return new Response(JSON.stringify({ error: "That person already owns this trip" }), {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const { data: existingRows, error: exErr } = await admin
        .from("trip_collaborators")
        .select("id, status")
        .eq("trip_id", tripId)
        .eq("user_id", inviteeUserId)
        .limit(1);

      if (exErr) {
        console.error("[send-invite-email] existing collab error:", exErr);
        return new Response(JSON.stringify({ error: "Could not check existing membership" }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const existing = existingRows?.[0] as { id: string; status: string } | undefined;
      if (existing?.status === "accepted") {
        return new Response(JSON.stringify({ error: "That person is already on this trip" }), {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      if (existing?.status === "pending") {
        await invokeSendNotification({
          supabaseUrl,
          serviceRoleKey,
          userId: inviteeUserId,
          tripId,
          tripName,
          inviterLabel,
          resent: true,
        });
        return new Response(
          JSON.stringify({ success: true, outcome: "in_app_notified", resent: true }),
          { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }

      if (existing?.status === "declined") {
        const { error: delDeclinedErr } = await admin.from("trip_collaborators").delete().eq("id", existing.id);
        if (delDeclinedErr) {
          console.error("[send-invite-email] delete declined row error:", delDeclinedErr);
          return new Response(JSON.stringify({ error: "Could not re-invite after a previous decline" }), {
            status: 500,
            headers: { ...corsHeaders, "Content-Type": "application/json" },
          });
        }
      }

      const { error: insErr } = await admin.from("trip_collaborators").insert({
        trip_id: tripId,
        user_id: inviteeUserId,
        role,
        invited_email: normalizedEmail,
        status: "pending",
      });

      if (insErr) {
        if (insErr.code === "23505") {
          await invokeSendNotification({
            supabaseUrl,
            serviceRoleKey,
            userId: inviteeUserId,
            tripId,
            tripName,
            inviterLabel,
            resent: true,
          });
          return new Response(
            JSON.stringify({ success: true, outcome: "in_app_notified", resent: true }),
            { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } },
          );
        }
        console.error("[send-invite-email] insert pending error:", insErr);
        return new Response(JSON.stringify({ error: insErr.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      await invokeSendNotification({
        supabaseUrl,
        serviceRoleKey,
        userId: inviteeUserId,
        tripId,
        tripName,
        inviterLabel,
        resent: false,
      });

      return new Response(
        JSON.stringify({ success: true, outcome: "in_app_notified", resent: false }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    if (!sendgridKey || !fromEmail) {
      return new Response(
        JSON.stringify({
          error:
            "Email delivery is not configured (SENDGRID_API_KEY and INVITE_FROM_EMAIL). Ask an admin to enable outbound email.",
        }),
        {
          status: 503,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

    const { data: existingInvites, error: invListErr } = await admin
      .from("trip_invites")
      .select("id, token, is_active, uses, max_uses, expires_at, role")
      .eq("trip_id", tripId)
      .eq("invited_email", normalizedEmail)
      .eq("is_active", true)
      .order("created_at", { ascending: false })
      .limit(1);

    if (invListErr) {
      console.error("[send-invite-email] list invites error:", invListErr);
      return new Response(JSON.stringify({ error: "Could not check existing invites" }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    let token: string;
    let inviteRowId: string;

    const prev = existingInvites?.[0] as
      | {
          id: string;
          token: string;
          is_active: boolean;
          uses: number;
          max_uses: number | null;
          expires_at: string | null;
          role: string;
        }
      | undefined;

    if (prev && isInviteValid(prev)) {
      token = prev.token;
      inviteRowId = prev.id;
      if (prev.role !== role) {
        await admin.from("trip_invites").update({ role }).eq("id", prev.id);
      }
    } else {
      token = randomInviteToken();
      const { data: inserted, error: insInvErr } = await admin
        .from("trip_invites")
        .insert({
          trip_id: tripId,
          created_by: user.id,
          token,
          role,
          max_uses: 1,
          is_active: true,
          invited_email: normalizedEmail,
        })
        .select("id")
        .single();

      if (insInvErr) {
        console.error("[send-invite-email] insert invite error:", insInvErr);
        return new Response(JSON.stringify({ error: insInvErr.message }), {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      inviteRowId = (inserted as { id: string }).id;
    }

    const inviteUrl = `${inviteBase}/${encodeURIComponent(token)}`;
    const roleLine = role === "editor" ? "edit the itinerary together" : "view the trip (read-only)";
    const subject = `You're invited to ${tripName} on Wayfind`;
    const text =
      `${inviterLabel} invited you to collaborate on “${tripName}”.\n\n` +
      `You'll be able to ${roleLine} after you open the link and join in the Wayfind app.\n\n` +
      `${inviteUrl}\n\n` +
      `If you don't have Wayfind yet, download it from the App Store or Google Play, then open this link again.`;

    const html =
      `<p><strong>${inviterLabel}</strong> invited you to collaborate on <strong>${escapeHtml(tripName)}</strong> in Wayfind.</p>` +
      `<p>You’ll be able to <strong>${escapeHtml(roleLine)}</strong> after you open the link in the Wayfind app.</p>` +
      `<p><a href="${inviteUrl}">Accept invite</a></p>` +
      `<p style="color:#666;font-size:13px;">If the button doesn’t work, copy this link:<br/>${escapeHtml(inviteUrl)}</p>`;

    const sg = await sendSendGridEmail({
      apiKey: sendgridKey,
      fromEmail,
      fromName: "Wayfind",
      toEmail: normalizedEmail,
      subject,
      text,
      html,
    });

    if (!sg.ok) {
      return new Response(JSON.stringify({ error: sg.message }), {
        status: 502,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const resent = Boolean(prev && isInviteValid(prev));
    return new Response(
      JSON.stringify({
        success: true,
        outcome: "email_sent",
        invite_id: inviteRowId,
        resent,
      }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (e) {
    console.error("[send-invite-email] unhandled:", e);
    return new Response(JSON.stringify({ error: "Internal server error" }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
