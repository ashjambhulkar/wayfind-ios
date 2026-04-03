import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { SignJWT, importPKCS8 } from "https://esm.sh/jose@5.9.6";

/**
 * Sends APNs alert pushes for all device tokens registered to a user.
 *
 * If HTTP/2 (or TLS) to Apple's production API is unreliable from the Edge runtime,
 * use `https://api.sandbox.push.apple.com` while developing with a sandbox device token,
 * or route pushes through a dedicated push proxy / provider (e.g. OneSignal, SNS).
 */
const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

const APNS_PRODUCTION_URL = "https://api.push.apple.com";

function jsonResponse(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function decodePemFromEnv(base64P8: string): string {
  const binary = atob(base64P8.trim());
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return new TextDecoder().decode(bytes);
}

async function createApnsJwt(
  pem: string,
  keyId: string,
  teamId: string,
): Promise<string> {
  const key = await importPKCS8(pem, "ES256");
  return await new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: keyId })
    .setIssuer(teamId)
    .setIssuedAt()
    .setExpirationTime("50m")
    .sign(key);
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return jsonResponse(405, { ok: false, error: "method_not_allowed" });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const apnsKeyId = Deno.env.get("APNS_KEY_ID");
  const apnsTeamId = Deno.env.get("APNS_TEAM_ID");
  const apnsAuthKeyB64 = Deno.env.get("APNS_AUTH_KEY");
  const bundleId = Deno.env.get("APP_BUNDLE_ID");

  if (
    !supabaseUrl ||
    !serviceRoleKey ||
    !apnsKeyId ||
    !apnsTeamId ||
    !apnsAuthKeyB64 ||
    !bundleId
  ) {
    return jsonResponse(500, {
      ok: false,
      error: "missing_apns_or_supabase_config",
    });
  }

  let body: {
    user_id?: string;
    title?: string;
    body?: string;
    data?: Record<string, unknown>;
  };
  try {
    body = await req.json();
  } catch {
    return jsonResponse(400, { ok: false, error: "invalid_json" });
  }

  const userId = body.user_id;
  const title = body.title;
  const alertBody = body.body;
  const extra = body.data;

  if (
    typeof userId !== "string" ||
    typeof title !== "string" ||
    typeof alertBody !== "string"
  ) {
    return jsonResponse(400, {
      ok: false,
      error: "user_id_title_and_body_strings_required",
    });
  }

  const supabase = createClient(supabaseUrl, serviceRoleKey);

  const { data: rows, error: tokenError } = await supabase
    .from("device_tokens")
    .select("id, token")
    .eq("user_id", userId);

  if (tokenError) {
    console.error("device_tokens select:", tokenError);
    return jsonResponse(500, { ok: false, error: "token_lookup_failed" });
  }

  if (!rows?.length) {
    return jsonResponse(200, {
      ok: true,
      sent: 0,
      message: "no_device_tokens",
    });
  }

  let pem: string;
  try {
    pem = decodePemFromEnv(apnsAuthKeyB64);
  } catch (e) {
    console.error("APNS_AUTH_KEY decode:", e);
    return jsonResponse(500, { ok: false, error: "apns_key_decode_failed" });
  }

  let jwt: string;
  try {
    jwt = await createApnsJwt(pem, apnsKeyId, apnsTeamId);
  } catch (e) {
    console.error("APNs JWT:", e);
    return jsonResponse(500, { ok: false, error: "apns_jwt_failed" });
  }

  const payload: Record<string, unknown> = {
    aps: {
      alert: { title, body: alertBody },
      sound: "default",
    },
  };
  if (extra && typeof extra === "object") {
    for (const [k, v] of Object.entries(extra)) {
      if (k !== "aps") payload[k] = v;
    }
  }

  const payloadJson = JSON.stringify(payload);
  let sent = 0;
  const errors: string[] = [];

  for (const row of rows) {
    const deviceToken = row.token as string;
    const url = `${APNS_PRODUCTION_URL}/3/device/${deviceToken}`;

    const res = await fetch(url, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${jwt}`,
        "apns-topic": bundleId,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "content-type": "application/json",
      },
      body: payloadJson,
    });

    if (res.ok) {
      sent++;
      continue;
    }

    if (res.status === 410) {
      const { error: delErr } = await supabase
        .from("device_tokens")
        .delete()
        .eq("token", deviceToken);
      if (delErr) {
        console.error("device_tokens delete after 410:", delErr);
      }
      errors.push(`410_gone:${deviceToken.slice(0, 8)}…`);
      continue;
    }

    const errText = await res.text();
    errors.push(`apns_${res.status}:${errText.slice(0, 200)}`);
  }

  return jsonResponse(200, {
    ok: true,
    sent,
    attempted: rows.length,
    errors: errors.length ? errors : undefined,
  });
});
