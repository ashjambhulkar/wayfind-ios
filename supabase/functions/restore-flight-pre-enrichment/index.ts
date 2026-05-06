/**
 * restore-flight-pre-enrichment — rolls back `trip_bookings.details_json`
 * to the snapshot taken by `backfill-flight-timezones`.
 *
 * Only restores rows that have a `pre_enrichment_snapshot` key in
 * `details_json`. Clears the snapshot after restoring so the row is clean.
 *
 * Usage:
 *   supabase functions invoke restore-flight-pre-enrichment --no-verify-jwt
 *   supabase functions invoke restore-flight-pre-enrichment --no-verify-jwt \
 *     --body '{"dry_run": true}'
 */

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { initSentry, safeLog } from "../_shared/observability.ts";

const FUNCTION_NAME = "restore-flight-pre-enrichment";

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

serve(async (req) => {
  initSentry();

  if (req.method === "OPTIONS") {
    return new Response("ok", { status: 200 });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRole = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRole) return json({ error: "not_configured" }, 500);

  const client = createClient(supabaseUrl, serviceRole, { auth: { persistSession: false } });

  let dryRun = false;
  try {
    const body = await req.json();
    if (body.dry_run === true) dryRun = true;
  } catch { /* optional */ }

  safeLog("info", FUNCTION_NAME, "start", { dryRun });

  // Fetch all bookings that have a pre_enrichment_snapshot.
  const { data, error } = await client
    .from("trip_bookings")
    .select("id, details_json")
    .eq("kind", "flight")
    .not("details_json->pre_enrichment_snapshot", "is", null);

  if (error) return json({ error: error.message }, 500);
  if (!data || data.length === 0) return json({ restored: 0, dry_run: dryRun });

  let restored = 0;
  for (const row of data) {
    const d = row.details_json as Record<string, unknown>;
    const snapshot = d["pre_enrichment_snapshot"] as Record<string, unknown>;
    if (!snapshot) continue;

    if (!dryRun) {
      // Remove the snapshot key from the restored value so the row is clean.
      const { pre_enrichment_snapshot: _, ...clean } = snapshot;
      const { error: updErr } = await client
        .from("trip_bookings")
        .update({ details_json: clean })
        .eq("id", row.id);
      if (updErr) {
        safeLog("warn", FUNCTION_NAME, "restore_error", { id: row.id, error: updErr.message });
        continue;
      }
    }
    restored++;
  }

  safeLog("info", FUNCTION_NAME, "complete", { restored, dryRun });
  return json({ restored, dry_run: dryRun });
});
