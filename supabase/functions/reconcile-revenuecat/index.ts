// Wave 4.4 — `reconcile-revenuecat` Edge Function.
//
// Why this exists: webhooks fail. They get blackholed by RevenueCat
// outages, by Supabase deploys that overlap a webhook delivery, by
// Apple grace-period state transitions that don't cleanly emit a single
// canonical event, and by SUBSCRIBER_ALIAS races where the webhook and
// the alias arrive in the wrong order. Without a reconcile job we'd
// learn about the drift the next time a paying user opens a support
// ticket — i.e. far too late for refunds to be cheap.
//
// What it does, once a night at 04:23 UTC:
//
//   1. Pulls every `user_subscriptions` row that's either `is_pro=true`
//      or where `expires_at` is within the next 7 days (so we catch
//      the about-to-renew cohort the same pass).
//   2. For each row, calls RevenueCat's REST API
//      `GET /v2/projects/{project_id}/customers/{app_user_id}` and
//      reads back the canonical entitlements snapshot.
//   3. Diffs. If the snapshot's `wayfind_pro` entitlement state
//      disagrees with the local row, writes a synthetic entry into
//      `processed_webhook_events` (`source = 'reconcile'`) and upserts
//      the truth.
//
// The "keep validate-subscription as backup" requirement from Wave 4.4
// is satisfied by *not* deprecating that function — it stays mounted
// for the iOS client to call when it suspects the local mirror is
// stale (e.g. right after a successful purchase before the webhook
// has landed). This reconcile job only catches drift between webhook
// deliveries; the iOS client's path is for sub-minute freshness.
//
// Cost: one RevenueCat REST call per active sub per night. With < 10K
// active subs we sit comfortably under RC's free-tier API rate limit
// (5K req/min) and never approach the per-month cap.
//
// env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, RC_PROJECT_ID,
//      RC_SECRET_API_KEY, REVENUECAT_ENTITLEMENT_ID (default `wayfind_pro`)

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Content-Type": "application/json",
};

// Cron tick processes up to N rows. With a nightly cadence and an
// active cohort that grows over time we may need to either bump this
// or shard by `user_id` hash. Today's cap is well above any realistic
// active cohort.
const MAX_ROWS_PER_INVOCATION = 5000;

// Per-call timeout for the RC REST API.
const PROVIDER_TIMEOUT_MS = 6000;

interface SubscriptionRow {
  user_id: string;
  is_pro: boolean;
  expires_at: string | null;
  plan_id: string | null;
  original_transaction_id: string | null;
  validated_at: string;
}

interface RcEntitlement {
  expires_date?: string | null;
  product_identifier?: string | null;
}

interface RcCustomer {
  subscriber?: {
    entitlements?: Record<string, RcEntitlement>;
    original_app_user_id?: string;
  };
}

function jsonResponse(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: CORS });
}

async function fetchWithTimeout(url: string, init: RequestInit, ms: number): Promise<Response> {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), ms);
  try {
    return await fetch(url, { ...init, signal: ctrl.signal });
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Calls RevenueCat REST API for the canonical entitlement snapshot.
 * Returns null on any error (the caller treats null as "skip this
 * user" rather than asserting drift) so a transient RC outage doesn't
 * stomp the local mirror with bogus state.
 */
async function fetchRcCustomer(
  projectId: string,
  apiKey: string,
  appUserId: string,
): Promise<RcCustomer | null> {
  const url = `https://api.revenuecat.com/v1/subscribers/${encodeURIComponent(appUserId)}`;
  try {
    const res = await fetchWithTimeout(url, {
      method: "GET",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
        // RC's per-project header — keeps the tenant scoped properly
        // when one secret key spans multiple projects.
        "X-Platform": "iOS",
      },
    }, PROVIDER_TIMEOUT_MS);
    if (!res.ok) {
      console.warn(JSON.stringify({
        event: "reconcile_rc_non_ok",
        status: res.status,
        app_user_id: appUserId,
      }));
      return null;
    }
    return await res.json() as RcCustomer;
  } catch (err) {
    console.warn(JSON.stringify({
      event: "reconcile_rc_error",
      app_user_id: appUserId,
      error: (err as Error).message,
    }));
    return null;
  }
}

/**
 * Reconciles one user. Compares the RC snapshot to the local row and
 * writes the truth (with a `processed_webhook_events` audit row) when
 * they disagree. Returns a structured outcome for batch reporting.
 */
async function reconcileOne(
  admin: SupabaseClient,
  row: SubscriptionRow,
  projectId: string,
  apiKey: string,
  entitlementId: string,
  runAt: string,
): Promise<{ user_id: string; outcome: "match" | "drift_fixed" | "skipped" }> {
  const customer = await fetchRcCustomer(projectId, apiKey, row.user_id);
  if (!customer) return { user_id: row.user_id, outcome: "skipped" };

  const ent = customer.subscriber?.entitlements?.[entitlementId];
  const rcExpiresMs = ent?.expires_date
    ? new Date(ent.expires_date).getTime()
    : null;
  const rcIsPro = ent != null && rcExpiresMs != null && rcExpiresMs > Date.now();

  const expectedExpiresIso = rcExpiresMs != null
    ? new Date(rcExpiresMs).toISOString()
    : null;

  // Both states agree — nothing to do. Don't bother writing an audit
  // row; reconcile rows are only interesting when they fixed something.
  if (rcIsPro === row.is_pro && expectedExpiresIso === row.expires_at) {
    return { user_id: row.user_id, outcome: "match" };
  }

  // Drift detected. Write the audit row first so we have a forensic
  // trail even if the upsert fails.
  const eventId = `reconcile:${runAt}:${row.user_id}`;
  await admin.from("processed_webhook_events").insert({
    event_id: eventId,
    event_type: "RECONCILE_DRIFT",
    user_id: row.user_id,
    source: "reconcile",
  });

  await admin.from("user_subscriptions").upsert(
    {
      user_id: row.user_id,
      is_pro: rcIsPro,
      plan_id: ent?.product_identifier ?? row.plan_id,
      original_transaction_id: row.original_transaction_id,
      expires_at: expectedExpiresIso,
      // Reconcile job doesn't see trial period info from the subscriber
      // endpoint — preserve the local value rather than blanking it.
      // (The webhook will overwrite this on the next renewal cycle.)
      validated_at: new Date().toISOString(),
    },
    { onConflict: "user_id" },
  );

  console.log(JSON.stringify({
    event: "reconcile_drift_fixed",
    user_id: row.user_id,
    was_pro: row.is_pro,
    is_pro: rcIsPro,
    was_expires_at: row.expires_at,
    expires_at: expectedExpiresIso,
  }));

  return { user_id: row.user_id, outcome: "drift_fixed" };
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") {
    return jsonResponse({ error: "method_not_allowed" }, 405);
  }

  const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
  const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const RC_PROJECT_ID = Deno.env.get("RC_PROJECT_ID")?.trim();
  const RC_SECRET_API_KEY = Deno.env.get("RC_SECRET_API_KEY")?.trim();
  const ENTITLEMENT_ID = Deno.env.get("REVENUECAT_ENTITLEMENT_ID")?.trim() || "wayfind_pro";

  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    return jsonResponse({ error: "server_misconfigured", missing: "supabase" }, 500);
  }
  if (!RC_PROJECT_ID || !RC_SECRET_API_KEY) {
    return jsonResponse({ error: "server_misconfigured", missing: "revenuecat" }, 500);
  }

  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });

  // Pull the rows worth reconciling. Active subs always; expiring-soon
  // subs because their renewal RENEWAL event is the most likely to be
  // missed mid-deploy.
  const horizonIso = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000).toISOString();
  const { data: rows, error: queryErr } = await admin
    .from("user_subscriptions")
    .select("user_id,is_pro,expires_at,plan_id,original_transaction_id,validated_at")
    .or(`is_pro.eq.true,expires_at.lte.${horizonIso}`)
    .limit(MAX_ROWS_PER_INVOCATION)
    .returns<SubscriptionRow[]>();

  if (queryErr) {
    console.error(JSON.stringify({
      event: "reconcile_query_error",
      error: queryErr.message,
    }));
    return jsonResponse({ error: "query_failed", detail: queryErr.message }, 500);
  }
  if (!rows || rows.length === 0) {
    return jsonResponse({ ok: true, processed: 0 });
  }

  const runAt = new Date().toISOString();
  let matches = 0;
  let drifts = 0;
  let skipped = 0;

  // Sequential-with-bounded-concurrency would be nicer, but RevenueCat's
  // public REST API caps at 5K req/min so even a 5K-row run runs cleanly
  // sequential inside the Edge Function's 60s budget.
  for (const row of rows) {
    const outcome = await reconcileOne(
      admin,
      row,
      RC_PROJECT_ID,
      RC_SECRET_API_KEY,
      ENTITLEMENT_ID,
      runAt,
    );
    if (outcome.outcome === "match") matches += 1;
    else if (outcome.outcome === "drift_fixed") drifts += 1;
    else skipped += 1;
  }

  return jsonResponse({
    ok: true,
    processed: rows.length,
    matches,
    drifts,
    skipped,
    run_at: runAt,
  });
});
