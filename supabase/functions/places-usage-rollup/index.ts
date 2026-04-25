/**
 * places-usage-rollup
 *
 * Phase G.1 (places-cost-and-owned-data plan).
 *
 * Bins yesterday's `places_usage_events` rows into the
 * `places_usage_daily` aggregate the cost dashboard reads from, then
 * deletes anything older than 35 days from the events table to keep
 * the raw log small.
 *
 * Triggered by pg_cron every night at 02:30 UTC (see
 * 20260601240000_places_usage_telemetry.sql). Safe to invoke
 * manually — running twice for the same day is a no-op idempotent
 * upsert.
 *
 * Body: `{}` (no parameters).
 *
 * Auth: service-role bearer token. The cron job mints one out of
 * `app.supabase_service_role_key`.
 */

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

// Days of raw events to keep. Anything older is pruned at the end of
// every successful rollup. 35 = the plan's documented retention so a
// month-end audit always has full per-call detail.
const RAW_EVENT_RETENTION_DAYS = 35;

type AggregateRow = {
  api: string;
  status: string;
  count: number;
};

Deno.serve(async (req) => {
  const auth = req.headers.get("authorization") ?? "";
  if (!auth.startsWith("Bearer ")) {
    return json({ error: "unauthorized" }, 401);
  }

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });

  const target = yesterdayUtc();

  try {
    const aggregates = await loadAggregates(admin, target);
    if (aggregates.length === 0) {
      console.log(
        `[places-usage-rollup] no events for ${target}, skipping upsert.`,
      );
    } else {
      await upsertDaily(admin, target, aggregates);
      console.log(
        `[places-usage-rollup] upserted ${aggregates.length} rows for ${target}.`,
      );
    }

    const pruned = await pruneOldEvents(admin);
    if (pruned != null) {
      console.log(
        `[places-usage-rollup] pruned ${pruned} events older than ${RAW_EVENT_RETENTION_DAYS}d.`,
      );
    }

    return json({
      ok: true,
      day: target,
      rows: aggregates.length,
      pruned: pruned ?? 0,
    });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("[places-usage-rollup] failed:", message);
    return json({ error: message }, 500);
  }
});

/**
 * Read every event from `target` and group in JS. We keep this in JS
 * (not pure SQL) so the rollup logic is greppable next to the schema
 * and so we can extend it with derived metrics (e.g. p95 of `meta`)
 * without rewriting a SQL aggregate.
 *
 * `(api, status)` cardinality is tiny (~10) so even on a high-traffic
 * day we read ≤ a few hundred thousand events back; far below the 1M
 * row default Supabase response cap.
 */
async function loadAggregates(
  admin: ReturnType<typeof createClient>,
  day: string,
): Promise<AggregateRow[]> {
  const counts = new Map<string, number>();
  const PAGE_SIZE = 50_000;
  let page = 0;
  while (true) {
    const from = page * PAGE_SIZE;
    const to = from + PAGE_SIZE - 1;
    const { data, error } = await admin
      .from("places_usage_events")
      .select("api, status")
      .eq("day", day)
      .range(from, to);
    if (error) throw new Error(`load page ${page}: ${error.message}`);
    if (!data || data.length === 0) break;
    for (const row of data as { api: string; status: string }[]) {
      const key = `${row.api}\u0000${row.status}`;
      counts.set(key, (counts.get(key) ?? 0) + 1);
    }
    if (data.length < PAGE_SIZE) break;
    page += 1;
  }

  const out: AggregateRow[] = [];
  for (const [key, count] of counts) {
    const [api, status] = key.split("\u0000");
    out.push({ api, status, count });
  }
  return out;
}

async function upsertDaily(
  admin: ReturnType<typeof createClient>,
  day: string,
  rows: AggregateRow[],
): Promise<void> {
  const payload = rows.map((r) => ({
    day,
    api: r.api,
    status: r.status,
    count: r.count,
    updated_at: new Date().toISOString(),
  }));

  const { error } = await admin
    .from("places_usage_daily")
    .upsert(payload, { onConflict: "day,api,status" });
  if (error) throw new Error(`upsert daily: ${error.message}`);
}

async function pruneOldEvents(
  admin: ReturnType<typeof createClient>,
): Promise<number | null> {
  const cutoff = new Date();
  cutoff.setUTCDate(cutoff.getUTCDate() - RAW_EVENT_RETENTION_DAYS);
  const cutoffDay = cutoff.toISOString().slice(0, 10);

  const { error, count } = await admin
    .from("places_usage_events")
    .delete({ count: "estimated" })
    .lt("day", cutoffDay);
  if (error) {
    console.warn("[places-usage-rollup] prune failed:", error.message);
    return null;
  }
  return count ?? 0;
}

function yesterdayUtc(): string {
  const d = new Date();
  d.setUTCDate(d.getUTCDate() - 1);
  return d.toISOString().slice(0, 10);
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
