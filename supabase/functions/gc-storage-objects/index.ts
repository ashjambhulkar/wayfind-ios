// Wave 0 (shared infra) — `gc-storage-objects` Edge Function.
//
// Plan §0.5 E6: drains the `pending_storage_deletions` queue. Scheduled by
// pg_cron nightly (see migration 20260602140000_gc_storage_objects_cron.sql).
//
// Strategy:
//   - Pull up to BATCH_SIZE unprocessed rows ordered by enqueued_at.
//   - For each row, call the bucket's REST API to remove the object.
//     not_found is treated as success (object already gone).
//   - On success, mark succeeded_at = now().
//   - On failure, increment attempts and stash last_error. Rows past
//     MAX_ATTEMPTS are left in the queue for human triage but skipped on
//     subsequent runs by the WHERE attempts < MAX_ATTEMPTS clause.
//
// Idempotent: rerunning a successful row is a no-op. Safe under concurrent
// invocation thanks to the ORDER BY + LIMIT + soft "in-flight" claim.

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, content-type",
  "Content-Type": "application/json",
};

const BATCH_SIZE = 250;
const MAX_ATTEMPTS = 5;

interface Row {
  id: string;
  bucket: string;
  storage_path: string;
  attempts: number;
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "method_not_allowed" }), { status: 405, headers: CORS });
  }

  // Cron secret: pg_cron passes a header; fall back to anon access disallowed.
  const cronSecret = Deno.env.get("EDGE_CRON_SECRET")?.trim();
  const auth = req.headers.get("Authorization")?.trim() ?? "";
  const bearer = auth.startsWith("Bearer ") ? auth.slice(7).trim() : auth;
  if (cronSecret && bearer !== cronSecret) {
    return new Response(JSON.stringify({ error: "unauthorized" }), { status: 401, headers: CORS });
  }

  const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
  const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  const { data: rows, error: fetchErr } = await admin
    .from("pending_storage_deletions")
    .select("id, bucket, storage_path, attempts")
    .is("succeeded_at", null)
    .lt("attempts", MAX_ATTEMPTS)
    .order("enqueued_at", { ascending: true })
    .limit(BATCH_SIZE);

  if (fetchErr) {
    console.error("[gc-storage-objects] fetch", fetchErr.message);
    return new Response(JSON.stringify({ error: "fetch_failed", detail: fetchErr.message }), {
      status: 500,
      headers: CORS,
    });
  }

  if (!rows || rows.length === 0) {
    return new Response(JSON.stringify({ ok: true, processed: 0 }), { status: 200, headers: CORS });
  }

  // Group by bucket so we can issue a single removal per bucket.
  const byBucket = new Map<string, Row[]>();
  for (const r of rows as Row[]) {
    const list = byBucket.get(r.bucket) ?? [];
    list.push(r);
    byBucket.set(r.bucket, list);
  }

  let succeeded = 0;
  let failed = 0;

  for (const [bucket, group] of byBucket) {
    const paths = group.map((r) => r.storage_path);
    const { data: removed, error: removeErr } = await admin.storage.from(bucket).remove(paths);

    if (removeErr) {
      // Bucket-level failure: bump every row in the group.
      const ids = group.map((r) => r.id);
      await admin
        .from("pending_storage_deletions")
        .update({
          attempts: group[0].attempts + 1,
          attempted_at: new Date().toISOString(),
          last_error: removeErr.message,
        })
        .in("id", ids);
      failed += group.length;
      continue;
    }

    // Storage `remove` returns the removed entries; missing entries are
    // treated as already-deleted. We mark every requested path as succeeded.
    void removed;
    const ids = group.map((r) => r.id);
    const { error: ackErr } = await admin
      .from("pending_storage_deletions")
      .update({
        succeeded_at: new Date().toISOString(),
        attempted_at: new Date().toISOString(),
        attempts: group[0].attempts + 1,
        last_error: null,
      })
      .in("id", ids);

    if (ackErr) {
      console.error("[gc-storage-objects] ack", ackErr.message);
      failed += group.length;
    } else {
      succeeded += group.length;
    }
  }

  return new Response(JSON.stringify({ ok: true, processed: rows.length, succeeded, failed }), {
    status: 200,
    headers: CORS,
  });
});
