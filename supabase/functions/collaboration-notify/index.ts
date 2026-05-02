import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-wayfind-collab-secret",
  "Content-Type": "application/json",
};

const THROTTLE_MS = 5 * 60 * 1000;

const BATCHED_PUSH_ACTIONS = new Set([
  "activity_added",
  "activity_updated",
  "booking_added",
  "booking_updated",
  "trip_updated",
  "note_added",
  "note_updated",
  "checklist_added",
  "checklist_item_toggled",
  "day_reordered",
]);

const IN_APP_ONLY_DELETE_ACTIONS = new Set([
  "activity_deleted",
  "booking_deleted",
]);

type ActivityLogRow = {
  id: string;
  trip_id: string;
  user_id: string;
  action: string;
  entity_name: string | null;
  metadata: Record<string, unknown> | null;
};

function unauthorized(): Response {
  return new Response(JSON.stringify({ error: "Unauthorized" }), {
    status: 401,
    headers: CORS_HEADERS,
  });
}

function extractRecord(payload: unknown): Record<string, unknown> | null {
  if (!payload || typeof payload !== "object") return null;
  const p = payload as Record<string, unknown>;
  if (p.record && typeof p.record === "object") {
    return p.record as Record<string, unknown>;
  }
  if (typeof p.trip_id === "string" && typeof p.action === "string" && typeof p.user_id === "string") {
    return p;
  }
  return null;
}

function parseLogRow(r: Record<string, unknown>): ActivityLogRow | null {
  const id = typeof r.id === "string" ? r.id : null;
  const trip_id = typeof r.trip_id === "string" ? r.trip_id : null;
  const user_id = typeof r.user_id === "string" ? r.user_id : null;
  const action = typeof r.action === "string" ? r.action : null;
  if (!id || !trip_id || !user_id || !action) return null;
  const entity_name = typeof r.entity_name === "string" ? r.entity_name : null;
  const meta = r.metadata;
  const metadata =
    meta && typeof meta === "object" && !Array.isArray(meta)
      ? (meta as Record<string, unknown>)
      : null;
  return { id, trip_id, user_id, action, entity_name, metadata };
}

function voluntaryLeave(metadata: Record<string, unknown> | null): boolean {
  return metadata?.voluntary_leave === true;
}

function formatRole(role: string | null | undefined): string {
  if (role === "editor") return "Editor";
  if (role === "viewer") return "Viewer";
  return role?.trim() || "Member";
}

async function profileDisplayName(
  supabase: SupabaseClient,
  userId: string,
): Promise<string> {
  const { data } = await supabase
    .from("profiles")
    .select("display_name")
    .eq("id", userId)
    .maybeSingle();
  const n = (data as { display_name?: string } | null)?.display_name?.trim();
  return n && n.length > 0 ? n : "Someone";
}

async function fetchTripTitle(
  supabase: SupabaseClient,
  tripId: string,
): Promise<string> {
  const { data } = await supabase
    .from("trips")
    .select("name")
    .eq("id", tripId)
    .maybeSingle();
  const n = (data as { name?: string } | null)?.name?.trim();
  return n && n.length > 0 ? n : "your trip";
}

async function fetchTripOwnerId(
  supabase: SupabaseClient,
  tripId: string,
): Promise<string | null> {
  const { data } = await supabase
    .from("trips")
    .select("user_id")
    .eq("id", tripId)
    .maybeSingle();
  const id = (data as { user_id?: string } | null)?.user_id;
  return typeof id === "string" ? id : null;
}

/** Owner + accepted collaborators, excluding `excludeUserId`. */
async function fetchNotifyRecipients(
  supabase: SupabaseClient,
  tripId: string,
  excludeUserId: string,
): Promise<string[]> {
  const ids = new Set<string>();
  const ownerId = await fetchTripOwnerId(supabase, tripId);
  if (ownerId && ownerId !== excludeUserId) ids.add(ownerId);

  const { data: collabs } = await supabase
    .from("trip_collaborators")
    .select("user_id")
    .eq("trip_id", tripId)
    .eq("status", "accepted");

  for (const row of collabs ?? []) {
    const uid = (row as { user_id: string }).user_id;
    if (uid && uid !== excludeUserId) ids.add(uid);
  }
  return [...ids];
}

async function shouldThrottlePush(
  supabase: SupabaseClient,
  tripId: string,
  recipientId: string,
): Promise<boolean> {
  const { data } = await supabase
    .from("collaboration_push_throttle")
    .select("last_push_at")
    .eq("trip_id", tripId)
    .eq("user_id", recipientId)
    .maybeSingle();
  const row = data as { last_push_at?: string } | null;
  if (!row?.last_push_at) return false;
  return Date.now() - new Date(row.last_push_at).getTime() < THROTTLE_MS;
}

async function markThrottlePush(
  supabase: SupabaseClient,
  tripId: string,
  recipientId: string,
): Promise<void> {
  await supabase.from("collaboration_push_throttle").upsert(
    {
      trip_id: tripId,
      user_id: recipientId,
      last_push_at: new Date().toISOString(),
    },
    { onConflict: "trip_id,user_id" },
  );
}

async function sendNotification(
  supabase: SupabaseClient,
  args: {
    recipientId: string;
    type: string;
    title: string;
    body: string;
    tripId: string;
    idempotencyKey: string;
    skipPush?: boolean;
  },
): Promise<void> {
  const { error } = await supabase.functions.invoke("send-notification", {
    body: {
      userId: args.recipientId,
      type: args.type,
      title: args.title,
      body: args.body,
      data: { trip_id: args.tripId },
      idempotencyKey: args.idempotencyKey,
      skipPush: args.skipPush === true,
    },
  });
  if (error) {
    console.error("[collaboration-notify] send-notification invoke error:", error);
  }
}

async function handleLog(
  supabase: SupabaseClient,
  row: ActivityLogRow,
): Promise<void> {
  const { id: logId, trip_id: tripId, user_id: actorId, action, entity_name, metadata } = row;
  const tripTitle = await fetchTripTitle(supabase, tripId);
  const actorName = await profileDisplayName(supabase, actorId);

  if (action === "pending_invite_declined") {
    const ownerId = await fetchTripOwnerId(supabase, tripId);
    if (!ownerId || ownerId === actorId) return;
    const email =
      typeof metadata?.invited_email === "string" ? metadata.invited_email.trim() : "";
    const who = email || actorName;
    await sendNotification(supabase, {
      recipientId: ownerId,
      type: "collab_invite_declined",
      title: `Invite declined · ${tripTitle}`,
      body: `${who} declined their invite.`,
      tripId,
      idempotencyKey: `collab:${logId}:declined:owner:${ownerId}`,
    });
    return;
  }

  if (action === "collaborator_joined") {
    const ownerId = await fetchTripOwnerId(supabase, tripId);
    if (!ownerId || ownerId === actorId) return;
    const role = formatRole(
      typeof metadata?.role === "string" ? metadata.role : null,
    );
    await sendNotification(supabase, {
      recipientId: ownerId,
      type: "collab_invite_accepted",
      title: `${actorName} joined ${tripTitle}`,
      body: `${actorName} joined as ${role}.`,
      tripId,
      idempotencyKey: `collab:${logId}:joined:owner:${ownerId}`,
    });
    return;
  }

  if (action === "collaborator_left") {
    const voluntary = voluntaryLeave(metadata);
    if (voluntary) {
      const recipients = await fetchNotifyRecipients(supabase, tripId, actorId);
      for (const rid of recipients) {
        await sendNotification(supabase, {
          recipientId: rid,
          type: "collab_member_left",
          title: `${actorName} left ${tripTitle}`,
          body: `${actorName} left the trip.`,
          tripId,
          idempotencyKey: `collab:${logId}:left:${rid}`,
        });
      }
      return;
    }

    await sendNotification(supabase, {
      recipientId: actorId,
      type: "collab_removed_self",
      title: "Removed from trip",
      body: `You were removed from “${tripTitle}”.`,
      tripId,
      idempotencyKey: `collab:${logId}:removed:user:${actorId}`,
    });

    const others = await fetchNotifyRecipients(supabase, tripId, actorId);
    for (const rid of others) {
      await sendNotification(supabase, {
        recipientId: rid,
        type: "collab_member_removed",
        title: `Member removed from ${tripTitle}`,
        body: `${actorName} was removed from the trip.`,
        tripId,
        idempotencyKey: `collab:${logId}:removed:other:${rid}`,
      });
    }
    return;
  }

  if (action === "collaborator_role_changed") {
    const subjectId =
      typeof metadata?.subject_user_id === "string" ? metadata.subject_user_id : null;
    if (!subjectId) return;
    const toRole = formatRole(
      typeof metadata?.to_role === "string" ? metadata.to_role : null,
    );
    await sendNotification(supabase, {
      recipientId: subjectId,
      type: "collab_role_changed",
      title: "Your role was updated",
      body: `You are now a ${toRole} on “${tripTitle}”.`,
      tripId,
      idempotencyKey: `collab:${logId}:role:${subjectId}`,
    });
    return;
  }

  if (IN_APP_ONLY_DELETE_ACTIONS.has(action)) {
    const recipients = await fetchNotifyRecipients(supabase, tripId, actorId);
    const detail = entity_name?.trim() ? `“${entity_name.trim()}”` : "an item";
    const verb = action === "booking_deleted" ? "removed a booking" : "removed a place";
    for (const rid of recipients) {
      await sendNotification(supabase, {
        recipientId: rid,
        type: "collab_trip_edit_inapp",
        title: `${tripTitle} updated`,
        body: `${actorName} ${verb}: ${detail}.`,
        tripId,
        idempotencyKey: `collab:${logId}:del:${rid}`,
        skipPush: true,
      });
    }
    return;
  }

  if (BATCHED_PUSH_ACTIONS.has(action)) {
    const recipients = await fetchNotifyRecipients(supabase, tripId, actorId);
    const preview =
      entity_name?.trim() ? ` (${entity_name.trim()})` : "";
    for (const rid of recipients) {
      const throttled = await shouldThrottlePush(supabase, tripId, rid);
      await sendNotification(supabase, {
        recipientId: rid,
        type: "collab_trip_activity",
        title: `${tripTitle} updated`,
        body: `${actorName} made updates${preview}.`,
        tripId,
        idempotencyKey: `collab:${logId}:batch:${rid}`,
        skipPush: throttled,
      });
      if (!throttled) {
        await markThrottlePush(supabase, tripId, rid);
      }
    }
  }
}

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }

  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), {
      status: 405,
      headers: CORS_HEADERS,
    });
  }

  const expected = Deno.env.get("WAYFIND_COLLAB_NOTIFY_SECRET");
  const provided = req.headers.get("x-wayfind-collab-secret");
  if (!expected || provided !== expected) {
    return unauthorized();
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceKey) {
    return new Response(JSON.stringify({ error: "Server misconfigured" }), {
      status: 500,
      headers: CORS_HEADERS,
    });
  }

  const supabase = createClient(supabaseUrl, serviceKey);

  let payload: unknown;
  try {
    payload = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: "Invalid JSON" }), {
      status: 400,
      headers: CORS_HEADERS,
    });
  }

  const raw = extractRecord(payload);
  const row = raw ? parseLogRow(raw) : null;
  if (!row) {
    return new Response(JSON.stringify({ error: "Missing or invalid activity log record" }), {
      status: 400,
      headers: CORS_HEADERS,
    });
  }

  try {
    await handleLog(supabase, row);
  } catch (e) {
    console.error("[collaboration-notify] handleLog error:", e);
    return new Response(JSON.stringify({ error: "Handler failed" }), {
      status: 500,
      headers: CORS_HEADERS,
    });
  }

  return new Response(JSON.stringify({ ok: true }), {
    status: 200,
    headers: CORS_HEADERS,
  });
});
