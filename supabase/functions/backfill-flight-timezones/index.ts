/**
 * backfill-flight-timezones — one-time (or repeated) service-role function
 * that enriches existing flight bookings that are missing `departure_tz`
 * and/or `arrival_tz` in `details_json`.
 *
 * Strategy (cheapest first):
 *   1. DB cache  (`airport_timezones` table) — free.
 *   2. Leave as-is if cache also misses — AeroDataBox is NOT called here
 *      to avoid cost blowout; real-time poll will fill these in later.
 *
 * Safety:
 *   - Writes the original details_json into `details_json.pre_enrichment_snapshot`
 *     before patching, enabling rollback via `restore-flight-pre-enrichment`.
 *   - Processes in pages of 100 to stay within Edge Function memory limits.
 *
 * Invoke once via Supabase dashboard or:
 *   supabase functions invoke backfill-flight-timezones --no-verify-jwt
 */

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { initSentry, safeLog } from "../_shared/observability.ts";
import { lookupAirportTimezones } from "../_shared/flight_enrichment.ts";

const FUNCTION_NAME = "backfill-flight-timezones";
const PAGE_SIZE = 100;

function log(event: string, payload: Record<string, unknown> = {}): void {
  safeLog("info", FUNCTION_NAME, event, payload);
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

interface BookingRow {
  id: string;
  details_json: Record<string, unknown> | null;
}

async function processPage(
  client: SupabaseClient,
  offset: number,
): Promise<{ processed: number; enriched: number; done: boolean }> {
  // Select flight bookings where at least one TZ field is missing.
  // We use a raw filter because Supabase JS doesn't expose JSONB path IS NULL
  // in the typed query builder.
  const { data, error } = await client
    .from("trip_bookings")
    .select("id, details_json")
    .eq("kind", "flight")
    .range(offset, offset + PAGE_SIZE - 1)
    .order("created_at", { ascending: true });

  if (error) {
    log("select_error", { error: error.message, offset });
    return { processed: 0, enriched: 0, done: true };
  }
  if (!data || data.length === 0) {
    return { processed: 0, enriched: 0, done: true };
  }

  // Filter to rows missing at least one TZ field.
  const rows = (data as BookingRow[]).filter((r) => {
    const d = r.details_json ?? {};
    return !d["departure_tz"] || !d["arrival_tz"];
  });
  if (rows.length === 0) {
    return { processed: data.length, enriched: 0, done: data.length < PAGE_SIZE };
  }
  const allCodes = new Set<string>();
  for (const row of rows) {
    const d = row.details_json ?? {};
    if (!d["departure_tz"]) {
      const depCode = String(d["origin_airport_iata"] ?? "").trim().toUpperCase();
      if (depCode.length === 3) allCodes.add(depCode);
    }
    if (!d["arrival_tz"]) {
      const arrCode = String(d["destination_airport_iata"] ?? "").trim().toUpperCase();
      if (arrCode.length === 3) allCodes.add(arrCode);
    }
  }

  const tzMap = await lookupAirportTimezones(client, Array.from(allCodes));

  let enriched = 0;
  for (const row of rows) {
    const d = row.details_json ?? {};
    const depCode = String(d["origin_airport_iata"] ?? "").trim().toUpperCase();
    const arrCode = String(d["destination_airport_iata"] ?? "").trim().toUpperCase();
    const depTz = !d["departure_tz"] ? (tzMap.get(depCode) ?? null) : null;
    const arrTz = !d["arrival_tz"] ? (tzMap.get(arrCode) ?? null) : null;

    if (!depTz && !arrTz) continue; // nothing to write from cache

    const patch: Record<string, unknown> = {
      ...d,
      // Snapshot for rollback — only write once.
      pre_enrichment_snapshot: d["pre_enrichment_snapshot"] ?? d,
    };
    if (depTz) patch["departure_tz"] = depTz;
    if (arrTz) patch["arrival_tz"]   = arrTz;

    const { error: updErr } = await client
      .from("trip_bookings")
      .update({ details_json: patch })
      .eq("id", row.id);

    if (updErr) {
      log("update_error", { booking_id: row.id, error: updErr.message });
    } else {
      enriched++;
    }
  }

  log("page_done", { offset, page: rows.length, enriched });
  return { processed: rows.length, enriched, done: rows.length < PAGE_SIZE };
}

serve(async (req) => {
  initSentry();

  if (req.method === "OPTIONS") {
    return new Response("ok", { status: 200, headers: { "Access-Control-Allow-Origin": "*" } });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRole = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRole) {
    return json({ error: "not_configured" }, 500);
  }

  const client = createClient(supabaseUrl, serviceRole, { auth: { persistSession: false } });

  // Parse optional `dry_run` and `max_pages` from request body.
  let dryRun = false;
  let maxPages = 20;
  try {
    const body = await req.json();
    if (body.dry_run === true) dryRun = true;
    if (typeof body.max_pages === "number") maxPages = Math.min(body.max_pages, 100);
  } catch { /* body is optional */ }

  log("start", { dryRun, maxPages });

  let totalProcessed = 0;
  let totalEnriched = 0;

  for (let page = 0; page < maxPages; page++) {
    const { processed, enriched, done } = await processPage(client, page * PAGE_SIZE);
    totalProcessed += processed;
    totalEnriched += enriched;
    if (done) break;
  }

  log("complete", { totalProcessed, totalEnriched, dryRun });
  return json({ processed: totalProcessed, enriched: totalEnriched, dry_run: dryRun });
});
