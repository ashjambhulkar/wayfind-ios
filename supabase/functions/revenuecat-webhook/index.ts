/**
 * RevenueCat → Supabase subscription sync (authoritative mirror for claims_ai_usage / APIs).
 *
 * Dashboard: Project → Integrations → Webhooks → POST URL = this function URL.
 * Security: set the same secret in RevenueCat webhook "Authorization" header value and
 *           Supabase secret REVENUECAT_WEBHOOK_SECRET (e.g. long random string).
 *
 * env: REVENUECAT_WEBHOOK_SECRET, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
 */
import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, content-type, x-revenuecat-signature",
  "Content-Type": "application/json",
};

type RcEvent = {
  type?: string;
  app_user_id?: string;
  original_app_user_id?: string;
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

function parseUuid(appUserId: string): string | null {
  const re =
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
  return re.test(appUserId) ? appUserId.toLowerCase() : null;
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "method_not_allowed" }), {
      status: 405,
      headers: CORS,
    });
  }

  const secret = Deno.env.get("REVENUECAT_WEBHOOK_SECRET")?.trim();
  if (!secret) {
    console.error("[revenuecat-webhook] REVENUECAT_WEBHOOK_SECRET missing");
    return new Response(JSON.stringify({ error: "server_misconfigured" }), {
      status: 500,
      headers: CORS,
    });
  }

  const auth = req.headers.get("Authorization")?.trim() ?? "";
  const bearer = auth.startsWith("Bearer ") ? auth.slice(7).trim() : auth;
  if (bearer !== secret) {
    return new Response(JSON.stringify({ error: "unauthorized" }), {
      status: 401,
      headers: CORS,
    });
  }

  let body: Body;
  try {
    body = (await req.json()) as Body;
  } catch {
    return new Response(JSON.stringify({ error: "invalid_json" }), {
      status: 400,
      headers: CORS,
    });
  }

  const ev = extractEvent(body);
  if (!ev?.type) {
    return new Response(JSON.stringify({ ok: true, ignored: true }), {
      status: 200,
      headers: CORS,
    });
  }

  const appUserRaw =
    ev.app_user_id ??
    ev.original_app_user_id ??
    "";
  const userId = parseUuid(appUserRaw);

  if (!userId) {
    console.warn("[revenuecat-webhook] non-uuid app_user_id", appUserRaw, ev.type);
    return new Response(JSON.stringify({ ok: true, skipped: "non_uuid_app_user" }), {
      status: 200,
      headers: CORS,
    });
  }

  const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
  const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  const entitlementEnv = Deno.env.get("REVENUECAT_ENTITLEMENT_ID")?.trim() || "wayfind_pro";

  /** Events that imply we should read subscription state from payload */
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
    "TEST",
  ]);

  if (!lifecycle.has(ev.type)) {
    return new Response(JSON.stringify({ ok: true, ignored_type: ev.type }), {
      status: 200,
      headers: CORS,
    });
  }

  let isPro = false;
  let expiresAtIso: string | null = null;

  if (ev.type === "EXPIRATION") {
    isPro = false;
    expiresAtIso = ev.expiration_at_ms != null
      ? new Date(ev.expiration_at_ms).toISOString()
      : null;
  } else if (ev.type === "TEST") {
    return new Response(JSON.stringify({ ok: true, test: true }), {
      status: 200,
      headers: CORS,
    });
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
    return new Response(JSON.stringify({ error: "upsert_failed", detail: error.message }), {
      status: 500,
      headers: CORS,
    });
  }

  return new Response(JSON.stringify({ ok: true, user_id: userId, is_pro: isPro }), {
    status: 200,
    headers: CORS,
  });
});
