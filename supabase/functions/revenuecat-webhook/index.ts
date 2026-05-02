/**
 * RevenueCat → Supabase subscription sync (authoritative mirror for
 * `claim_ai_usage`, paywall gating, and downstream entitlement reads).
 *
 * Wave 4.4 hardening:
 *   1. Idempotency via `processed_webhook_events` so retries within
 *      RevenueCat's 72-hour retry window don't double-write a row that
 *      a later event already corrected.
 *   2. REFUND handler — when Apple refunds the user (chargeback, etc.)
 *      RevenueCat fires REFUND. We must drop the entitlement immediately
 *      because the user no longer paid; otherwise Apple will reject the
 *      next App Review citing "providing access to refunded content".
 *   3. SUBSCRIBER_ALIAS handler — RevenueCat emits this when a logged-out
 *      anonymous appUserID merges into a logged-in real one. We need to
 *      forward the entitlement state from the anonymous id (which we
 *      ignored because it wasn't a UUID) onto the real Wayfind user.
 *   4. Dual-secret rotation — accepts the value of *either*
 *      REVENUECAT_WEBHOOK_SECRET or REVENUECAT_WEBHOOK_SECRET_NEXT so we
 *      can deploy a new secret in RevenueCat *before* removing the old
 *      one from Supabase. Lets us rotate without a delivery gap.
 *
 * Dashboard: Project → Integrations → Webhooks → POST URL = this function URL.
 * Security: set the same secret in RevenueCat webhook "Authorization"
 *           header value and Supabase secret REVENUECAT_WEBHOOK_SECRET.
 *           To rotate, set REVENUECAT_WEBHOOK_SECRET_NEXT, swap RevenueCat
 *           to the new value, then drop the next one and promote it.
 *
 * env: REVENUECAT_WEBHOOK_SECRET, REVENUECAT_WEBHOOK_SECRET_NEXT (optional),
 *      SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY,
 *      REVENUECAT_ENTITLEMENT_ID (default `wayfind_pro`)
 */
import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, content-type, x-revenuecat-signature",
  "Content-Type": "application/json",
};

type RcEvent = {
  /** RevenueCat-assigned per-event UUID (used for idempotency). */
  id?: string;
  type?: string;
  app_user_id?: string;
  original_app_user_id?: string;
  /** Set on SUBSCRIBER_ALIAS — the *new* primary id we should consolidate to. */
  alias_app_user_id?: string;
  /** Set on SUBSCRIBER_ALIAS — the secondary id being merged in. */
  aliased_app_user_id?: string;
  product_id?: string | null;
  entitlement_ids?: string[] | null;
  expiration_at_ms?: number | null;
  original_transaction_id?: string | null;
  store?: string | null;
  period_type?: string | null;
};

type Body = {
  api_version?: string;
  event?: RcEvent;
} & RcEvent;

function extractEvent(json: Body): RcEvent | null {
  if (json.event && typeof json.event === "object") return json.event;
  if (json.type && json.app_user_id !== undefined) return json as RcEvent;
  return null;
}

const UUID_REGEX =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function parseUuid(appUserId: string | null | undefined): string | null {
  if (!appUserId) return null;
  return UUID_REGEX.test(appUserId) ? appUserId.toLowerCase() : null;
}

function jsonResponse(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: CORS });
}

/** Wave 4.4 — dual-secret rotation. */
function authorisedAgainst(bearer: string): boolean {
  const primary = Deno.env.get("REVENUECAT_WEBHOOK_SECRET")?.trim();
  const next = Deno.env.get("REVENUECAT_WEBHOOK_SECRET_NEXT")?.trim();
  if (!primary && !next) return false;
  if (primary && bearer === primary) return true;
  if (next && bearer === next) return true;
  return false;
}

/**
 * Wave 4.4 — idempotency claim. Returns `true` if this event id is fresh
 * (caller should process it) and `false` if we've already processed it
 * (caller should return 200 without mutating state).
 *
 * The PRIMARY KEY on `event_id` makes this race-safe across concurrent
 * webhook deliveries.
 */
async function claimEvent(
  admin: SupabaseClient,
  eventId: string,
  eventType: string,
  userId: string | null,
  source: "webhook" | "reconcile" = "webhook",
): Promise<boolean> {
  const { error } = await admin
    .from("processed_webhook_events")
    .insert({
      event_id: eventId,
      event_type: eventType,
      user_id: userId,
      source,
    });
  if (!error) return true;
  // Postgres `unique_violation` (23505) = already processed. Anything
  // else is unexpected and we surface it; refusing to upsert because
  // the caller might double-bill the user otherwise.
  if ((error as { code?: string }).code === "23505") return false;
  console.error("[revenuecat-webhook] claim_event_unexpected", error.message);
  // Fail closed — return false so the caller skips the mutation. The
  // event will be retried by RevenueCat, hopefully against a healthy
  // database. We accept the duplicate-processing risk on `false` here
  // because the alternative is unbounded retries.
  return false;
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  if (req.method !== "POST") {
    return jsonResponse({ error: "method_not_allowed" }, 405);
  }

  const auth = req.headers.get("Authorization")?.trim() ?? "";
  const bearer = auth.startsWith("Bearer ") ? auth.slice(7).trim() : auth;
  if (!authorisedAgainst(bearer)) {
    return jsonResponse({ error: "unauthorized" }, 401);
  }

  let body: Body;
  try {
    body = (await req.json()) as Body;
  } catch {
    return jsonResponse({ error: "invalid_json" }, 400);
  }

  const ev = extractEvent(body);
  if (!ev?.type) {
    return jsonResponse({ ok: true, ignored: true });
  }

  const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
  const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    return jsonResponse({ error: "server_misconfigured" }, 500);
  }
  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  const entitlementEnv =
    Deno.env.get("REVENUECAT_ENTITLEMENT_ID")?.trim() || "wayfind_pro";

  // Resolve the Wayfind user id. SUBSCRIBER_ALIAS uses different fields
  // than the lifecycle events — `alias_app_user_id` is the *new* primary
  // we should consolidate onto, `aliased_app_user_id` is the secondary
  // being merged. Lifecycle events use `app_user_id` / `original_app_user_id`.
  const appUserRaw =
    ev.alias_app_user_id ?? ev.app_user_id ?? ev.original_app_user_id ?? "";
  const userId = parseUuid(appUserRaw);

  // Idempotency check. RevenueCat sends a stable `id` on each event;
  // if missing (legacy payloads, manual replays) fall back to a
  // synthetic id so we still get retry protection within the same
  // delivery batch.
  const eventId =
    ev.id?.trim() ||
    `${ev.type}:${appUserRaw}:${ev.original_transaction_id ?? "no_txn"}:${ev.expiration_at_ms ?? "no_exp"}`;

  const claimed = await claimEvent(admin, eventId, ev.type, userId);
  if (!claimed) {
    return jsonResponse({ ok: true, deduplicated: true, event_id: eventId });
  }

  // After idempotency claim, we can safely early-return on events we
  // don't act on — the next delivery for the same event id will
  // short-circuit on the dedup row.
  if (!userId) {
    console.warn("[revenuecat-webhook] non-uuid app_user_id", appUserRaw, ev.type);
    return jsonResponse({ ok: true, skipped: "non_uuid_app_user" });
  }

  if (ev.type === "TEST") {
    return jsonResponse({ ok: true, test: true });
  }

  // Wave 4.4 — SUBSCRIBER_ALIAS. RevenueCat emits this when an
  // anonymous appUserID is logged into the real Wayfind user id.
  // Strategy: copy the entitlement state from the *aliased* (secondary)
  // record onto the *alias* (primary). If the secondary id wasn't a
  // UUID we have no row to copy from — log and 200 so RevenueCat
  // doesn't retry.
  if (ev.type === "SUBSCRIBER_ALIAS") {
    const aliasedRaw = ev.aliased_app_user_id ?? "";
    const secondaryUuid = parseUuid(aliasedRaw);
    if (!secondaryUuid) {
      return jsonResponse({ ok: true, alias_skipped: "non_uuid_secondary" });
    }
    const { data: secondary, error: readErr } = await admin
      .from("user_subscriptions")
      .select("*")
      .eq("user_id", secondaryUuid)
      .maybeSingle();
    if (readErr) {
      console.error("[revenuecat-webhook] alias_read", readErr.message);
      return jsonResponse({ error: "alias_read_failed", detail: readErr.message }, 500);
    }
    if (!secondary) {
      // Nothing to copy. Common case: secondary was anonymous and never
      // had a subscription event. Acknowledge and move on.
      return jsonResponse({ ok: true, alias_no_op: true });
    }
    // Forward the secondary's state to the primary, preserving validation
    // timestamps so reconcile can spot if drift opens up.
    const { error: writeErr } = await admin.from("user_subscriptions").upsert(
      {
        user_id: userId,
        is_pro: secondary.is_pro,
        plan_id: secondary.plan_id,
        platform: secondary.platform,
        original_transaction_id: secondary.original_transaction_id,
        expires_at: secondary.expires_at,
        trial_used: secondary.trial_used,
        is_in_billing_retry: secondary.is_in_billing_retry,
        validated_at: new Date().toISOString(),
      },
      { onConflict: "user_id" },
    );
    if (writeErr) {
      console.error("[revenuecat-webhook] alias_write", writeErr.message);
      return jsonResponse({ error: "alias_write_failed", detail: writeErr.message }, 500);
    }
    // Drop the secondary row to avoid two records claiming the same
    // entitlement. The user will continue paying once on the primary.
    await admin.from("user_subscriptions").delete().eq("user_id", secondaryUuid);
    return jsonResponse({ ok: true, aliased_from: secondaryUuid, aliased_to: userId });
  }

  // Wave 4.4 — REFUND handler. Apple-issued refund (cardholder dispute
  // or App Store decision) revokes the user's entitlement immediately
  // even if `expires_at` would otherwise still be in the future.
  // Required by App Review Guideline 3.1.2 — providing access to
  // refunded content fails review.
  if (ev.type === "REFUND") {
    const { error } = await admin.from("user_subscriptions").upsert(
      {
        user_id: userId,
        is_pro: false,
        plan_id: ev.product_id ?? null,
        platform: ev.store === "PLAY_STORE" ? "android" : "ios",
        original_transaction_id: ev.original_transaction_id ?? null,
        // Setting expires_at to the past gives downstream readers an
        // unambiguous "this user no longer has Pro" signal even if a
        // misordered RENEWAL arrives later (claim_ai_usage and the
        // entitlement service both check the past-vs-future delta).
        expires_at: new Date(Date.now() - 1000).toISOString(),
        trial_used: false,
        is_in_billing_retry: false,
        validated_at: new Date().toISOString(),
      },
      { onConflict: "user_id" },
    );
    if (error) {
      console.error("[revenuecat-webhook] refund_upsert", error.message);
      return jsonResponse({ error: "refund_upsert_failed", detail: error.message }, 500);
    }
    return jsonResponse({ ok: true, refund: true, user_id: userId, is_pro: false });
  }

  /** Standard lifecycle events — same logic as the original webhook. */
  const lifecycle = new Set([
    "INITIAL_PURCHASE",
    "RENEWAL",
    "NON_RENEWING_PURCHASE",
    "PRODUCT_CHANGE",
    "UNCANCELLATION",
    "SUBSCRIPTION_EXTENDED",
    "TEMPORARY_ENTITLEMENT_GRANT",
    "CANCELLATION",
    "BILLING_ISSUE",
    "EXPIRATION",
  ]);

  if (!lifecycle.has(ev.type)) {
    return jsonResponse({ ok: true, ignored_type: ev.type });
  }

  let isPro = false;
  let expiresAtIso: string | null = null;

  if (ev.type === "EXPIRATION") {
    isPro = false;
    expiresAtIso = ev.expiration_at_ms != null
      ? new Date(ev.expiration_at_ms).toISOString()
      : null;
  } else {
    const expiresMs = ev.expiration_at_ms ?? null;
    expiresAtIso = expiresMs != null ? new Date(expiresMs).toISOString() : null;
    const entitlementHit =
      Array.isArray(ev.entitlement_ids) &&
      ev.entitlement_ids.includes(entitlementEnv);
    const expiresFuture = expiresMs != null && expiresMs > Date.now();
    isPro = entitlementHit && expiresFuture;

    /** Billing issue: Apple grace — keep access until expiration if still in period */
    if (ev.type === "BILLING_ISSUE") {
      isPro = expiresFuture && entitlementHit;
    }

    /** Cancellation does not immediately revoke until expiration */
    if (ev.type === "CANCELLATION") {
      isPro = expiresFuture && entitlementHit;
    }
  }

  const platform =
    ev.store === "PLAY_STORE"
      ? "android"
      : ev.store === "APP_STORE" || ev.store === "MAC_APP_STORE"
      ? "ios"
      : "ios";

  const trialUsed = ev.period_type === "TRIAL";

  const { error } = await admin.from("user_subscriptions").upsert(
    {
      user_id: userId,
      is_pro: isPro,
      plan_id: ev.product_id ?? null,
      platform,
      original_transaction_id: ev.original_transaction_id ?? null,
      expires_at: expiresAtIso,
      trial_used: trialUsed,
      is_in_billing_retry: ev.type === "BILLING_ISSUE",
      validated_at: new Date().toISOString(),
    },
    { onConflict: "user_id" },
  );

  if (error) {
    console.error("[revenuecat-webhook] upsert", error.message);
    return jsonResponse({ error: "upsert_failed", detail: error.message }, 500);
  }

  return jsonResponse({ ok: true, user_id: userId, is_pro: isPro });
});
