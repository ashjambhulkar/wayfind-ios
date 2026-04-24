import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Content-Type": "application/json",
};

type Body = {
  receipt?: string;
  product_id?: string;
  platform?: string;
};

type AppleLatestInfo = {
  expires_date_ms?: string;
  original_transaction_id?: string;
  product_id?: string;
  is_trial_period?: string;
};

async function verifyAppleReceipt(receiptBase64: string): Promise<{
  expiresAtIso: string | null;
  originalTransactionId: string | null;
  productId: string | null;
  trialUsed: boolean;
} | null> {
  const password = Deno.env.get("APPLE_SHARED_SECRET")?.trim();
  if (!password) {
    console.error("[validate-subscription] APPLE_SHARED_SECRET not set");
    return null;
  }

  const payload = {
    "receipt-data": receiptBase64,
    "password": password,
    "exclude-old-transactions": true,
  };

  const urls = [
    "https://buy.itunes.apple.com/verifyReceipt",
    "https://sandbox.itunes.apple.com/verifyReceipt",
  ] as const;

  let lastStatus: number | null = null;

  for (let i = 0; i < urls.length; i++) {
    const url = urls[i];
    const res = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });

    const json = (await res.json()) as {
      status?: number;
      latest_receipt_info?: AppleLatestInfo[];
      receipt?: { in_app?: AppleLatestInfo[] };
    };

    lastStatus = json.status ?? -1;

    if (json.status === 21007 && i === 0) {
      continue;
    }

    if (json.status !== 0) {
      console.error("[validate-subscription] Apple verifyReceipt status", json.status);
      return null;
    }

    const infos = json.latest_receipt_info ??
      json.receipt?.in_app ??
      [];
    if (!Array.isArray(infos) || infos.length === 0) {
      return {
        expiresAtIso: null,
        originalTransactionId: null,
        productId: null,
        trialUsed: false,
      };
    }

    let maxMs = 0;
    let origId: string | null = null;
    let prodId: string | null = null;
    let anyTrial = false;

    for (const row of infos) {
      const ms = Number(row.expires_date_ms ?? 0);
      if (ms > maxMs) {
        maxMs = ms;
        origId = row.original_transaction_id ?? null;
        prodId = row.product_id ?? null;
      }
      if (row.is_trial_period === "true") anyTrial = true;
    }

    return {
      expiresAtIso: maxMs > 0 ? new Date(maxMs).toISOString() : null,
      originalTransactionId: origId,
      productId: prodId,
      trialUsed: anyTrial,
    };
  }

  console.error("[validate-subscription] Apple verify exhausted", lastStatus);
  return null;
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

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), {
        status: 401,
        headers: CORS_HEADERS,
      });
    }

    const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
    const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
    const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

    const supabaseUser = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    });

    const { data: userData, error: userErr } = await supabaseUser.auth
      .getUser();
    const user = userData?.user;
    if (userErr || !user?.id) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), {
        status: 401,
        headers: CORS_HEADERS,
      });
    }

    const body = (await req.json()) as Body;
    const receipt = body.receipt?.trim();
    const productIdBody = body.product_id?.trim();
    const platform = body.platform?.toLowerCase().trim();

    if (!receipt || !platform) {
      return new Response(
        JSON.stringify({ error: "receipt and platform are required" }),
        { status: 400, headers: CORS_HEADERS },
      );
    }

    if (platform === "android") {
      return new Response(
        JSON.stringify({
          error: "not_implemented",
          message:
            "Google Play subscription validation requires a service account and the Play Developer API. Configure in a follow-up; see validate-subscription/README.md.",
        }),
        { status: 501, headers: CORS_HEADERS },
      );
    }

    if (platform !== "ios") {
      return new Response(JSON.stringify({ error: "platform must be ios or android" }), {
        status: 400,
        headers: CORS_HEADERS,
      });
    }

    const apple = await verifyAppleReceipt(receipt);
    if (!apple) {
      return new Response(
        JSON.stringify({
          error: "verification_failed",
          message:
            "Could not verify Apple receipt. Ensure APPLE_SHARED_SECRET is set and the receipt is valid.",
        }),
        { status: 503, headers: CORS_HEADERS },
      );
    }

    const now = Date.now();
    const expiresMs = apple.expiresAtIso
      ? Date.parse(apple.expiresAtIso)
      : 0;
    const isPro = expiresMs > now;
    const planId = productIdBody ?? apple.productId ?? null;

    const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    const { error: upsertErr } = await admin.from("user_subscriptions").upsert(
      {
        user_id: user.id,
        is_pro: isPro,
        plan_id: planId,
        platform: "ios",
        original_transaction_id: apple.originalTransactionId,
        expires_at: apple.expiresAtIso,
        trial_used: apple.trialUsed,
        is_in_billing_retry: false,
        validated_at: new Date().toISOString(),
      },
      { onConflict: "user_id" },
    );

    if (upsertErr) {
      console.error("[validate-subscription] upsert", upsertErr.message);
      return new Response(
        JSON.stringify({ error: "Failed to save subscription", detail: upsertErr.message }),
        { status: 500, headers: CORS_HEADERS },
      );
    }

    return new Response(
      JSON.stringify({
        ok: true,
        is_pro: isPro,
        expires_at: apple.expiresAtIso,
        plan_id: planId,
      }),
      { status: 200, headers: CORS_HEADERS },
    );
  } catch (e) {
    console.error("[validate-subscription]", e);
    return new Response(
      JSON.stringify({
        error: e instanceof Error ? e.message : "Internal error",
      }),
      { status: 500, headers: CORS_HEADERS },
    );
  }
});
