import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

function jsonResponse(body: Record<string, unknown>, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return jsonResponse({ error: "Missing authorization header" }, 401);
    }

    const userClient = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } },
    );

    const { data: { user }, error: userError } = await userClient.auth.getUser();
    if (userError || !user) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }

    const userId = user.id;

    const adminClient = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const fail = (step: string, err: { message: string }) => {
      console.error(`[delete-user] ${step}:`, err.message);
      return jsonResponse(
        { error: `${step}: ${err.message}` },
        500,
      );
    };

    // Avatar objects under `{userId}/{filename}`
    const { data: avatarFiles } = await adminClient.storage
      .from("avatars")
      .list(userId);

    if (avatarFiles && avatarFiles.length > 0) {
      const paths = avatarFiles.map((f) => `${userId}/${f.name}`);
      const { error: avErr } = await adminClient.storage.from("avatars").remove(
        paths,
      );
      if (avErr) {
        return fail("avatar storage", avErr);
      }
    }

    // Stop being a collaborator on others' trips (and drop owner collaborator rows if any).
    const { error: collabSelfErr } = await adminClient
      .from("trip_collaborators")
      .delete()
      .eq("user_id", userId);
    if (collabSelfErr) {
      return fail("trip_collaborators (by user)", collabSelfErr);
    }

    const { data: trips, error: tripsListErr } = await adminClient
      .from("trips")
      .select("id")
      .eq("user_id", userId);

    if (tripsListErr) {
      return fail("trips list", tripsListErr);
    }

    const tripIds = (trips ?? [])
      .map((t: { id: string }) => t.id)
      .filter((id: string) => typeof id === "string" && id.length > 0);

    if (tripIds.length > 0) {
      const { error: e1 } = await adminClient
        .from("trip_activity_attachments")
        .delete()
        .in("trip_id", tripIds);
      if (e1) return fail("trip_activity_attachments", e1);

      const { data: bookings, error: bookSelErr } = await adminClient
        .from("trip_bookings")
        .select("id")
        .in("trip_id", tripIds);
      if (bookSelErr) return fail("trip_bookings select", bookSelErr);

      const bookingIds = (bookings ?? [])
        .map((b: { id: string }) => b.id)
        .filter((id: string) => id.length > 0);

      if (bookingIds.length > 0) {
        const { error: e2 } = await adminClient
          .from("trip_booking_attachments")
          .delete()
          .in("booking_id", bookingIds);
        if (e2) return fail("trip_booking_attachments", e2);
      }

      const { error: e3 } = await adminClient
        .from("trip_activities")
        .delete()
        .in("trip_id", tripIds);
      if (e3) return fail("trip_activities", e3);

      const { error: e4 } = await adminClient
        .from("trip_bookings")
        .delete()
        .in("trip_id", tripIds);
      if (e4) return fail("trip_bookings", e4);

      const { error: e5 } = await adminClient
        .from("trip_days")
        .delete()
        .in("trip_id", tripIds);
      if (e5) return fail("trip_days", e5);

      const { error: eBudget } = await adminClient
        .from("trip_budgets")
        .delete()
        .in("trip_id", tripIds);
      if (eBudget) return fail("trip_budgets", eBudget);

      const { error: e6 } = await adminClient
        .from("trip_collaborators")
        .delete()
        .in("trip_id", tripIds);
      if (e6) return fail("trip_collaborators (by trip)", e6);

      const { error: e7 } = await adminClient
        .from("trip_invites")
        .delete()
        .in("trip_id", tripIds);
      if (e7) return fail("trip_invites", e7);

      const { error: e8 } = await adminClient
        .from("trip_activity_log")
        .delete()
        .in("trip_id", tripIds);
      if (e8) return fail("trip_activity_log", e8);

      const { error: e9 } = await adminClient
        .from("collaboration_push_throttle")
        .delete()
        .in("trip_id", tripIds);
      if (e9) return fail("collaboration_push_throttle", e9);

      const { error: e10 } = await adminClient
        .from("email_forwarding_queue")
        .delete()
        .in("trip_id", tripIds);
      if (e10) return fail("email_forwarding_queue", e10);
    }

    const { error: delTripsErr } = await adminClient
      .from("trips")
      .delete()
      .eq("user_id", userId);
    if (delTripsErr) {
      return fail("trips delete", delTripsErr);
    }

    const { error: fcmErr } = await adminClient
      .from("fcm_tokens")
      .delete()
      .eq("user_id", userId);
    if (fcmErr) {
      return fail("fcm_tokens", fcmErr);
    }

    const { error: profErr } = await adminClient
      .from("profiles")
      .delete()
      .eq("id", userId);
    if (profErr) {
      return fail("profiles", profErr);
    }

    const { error: deleteAuthError } = await adminClient.auth.admin.deleteUser(
      userId,
    );
    if (deleteAuthError) {
      console.error(
        "[delete-user] auth.admin.deleteUser:",
        deleteAuthError.message,
      );
      return jsonResponse({ error: "Failed to delete account" }, 500);
    }

    return jsonResponse({ success: true }, 200);
  } catch (err) {
    console.error("[delete-user] Unexpected error:", err);
    return jsonResponse({ error: "Internal server error" }, 500);
  }
});
