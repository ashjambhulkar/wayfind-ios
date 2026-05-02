import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  getToken as getGoogleAccessToken,
} from "https://deno.land/x/googlejwtsa@v0.1.8/mod.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const FIREBASE_PROJECT_ID = Deno.env.get("FIREBASE_PROJECT_ID")!;

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Content-Type": "application/json",
};

const FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging";
const FCM_URL = `https://fcm.googleapis.com/v1/projects/${FIREBASE_PROJECT_ID}/messages:send`;

let cachedAccessToken: string | null = null;
let tokenExpiresAt = 0;

async function getFcmAccessToken(): Promise<string> {
  const now = Date.now();
  if (cachedAccessToken && now < tokenExpiresAt - 60_000) {
    return cachedAccessToken;
  }

  const serviceAccountJson = Deno.env.get("FIREBASE_SERVICE_ACCOUNT");
  if (!serviceAccountJson) {
    throw new Error("FIREBASE_SERVICE_ACCOUNT secret not configured");
  }

  const serviceAccount = JSON.parse(serviceAccountJson);
  const token = await getGoogleAccessToken(serviceAccount, FCM_SCOPE);
  cachedAccessToken = token;
  tokenExpiresAt = now + 3_500_000;
  return token;
}

interface NotificationPayload {
  userId: string;
  type: string;
  title: string;
  body: string;
  data?: Record<string, string>;
  idempotencyKey?: string;
  /** When true, insert in-app row only (no FCM). Stage 12: e.g. activity_deleted. */
  skipPush?: boolean;
}

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }

  try {
    const payload: NotificationPayload = await req.json();
    const { userId, type, title, body, data, idempotencyKey, skipPush } = payload;

    if (!userId || !type || !title || !body) {
      return new Response(
        JSON.stringify({ error: "userId, type, title, and body are required" }),
        { status: 400, headers: CORS_HEADERS },
      );
    }

    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    // Idempotent insert: skip if notification already exists
    const insertData: Record<string, unknown> = {
      user_id: userId,
      type,
      title,
      body,
      data: data ?? {},
    };
    if (idempotencyKey) {
      insertData.idempotency_key = idempotencyKey;
    }

    const { data: inserted, error: insertError } = await supabase
      .from("notifications")
      .upsert(insertData, {
        onConflict: "user_id, idempotency_key",
        ignoreDuplicates: true,
      })
      .select("id")
      .maybeSingle();

    if (insertError) {
      console.error("Failed to insert notification:", insertError);
      return new Response(
        JSON.stringify({ error: "Failed to insert notification" }),
        { status: 500, headers: CORS_HEADERS },
      );
    }

    // If no row was inserted (duplicate), return early
    if (!inserted) {
      return new Response(
        JSON.stringify({ success: true, duplicate: true }),
        { status: 200, headers: CORS_HEADERS },
      );
    }

    if (skipPush === true) {
      return new Response(
        JSON.stringify({
          success: true,
          notificationId: inserted.id,
          pushSent: false,
          skippedPush: true,
        }),
        { status: 200, headers: CORS_HEADERS },
      );
    }

    // Fetch all FCM tokens for this user
    const { data: tokens, error: tokenError } = await supabase
      .from("fcm_tokens")
      .select("id, token")
      .eq("user_id", userId);

    if (tokenError) {
      console.error("Failed to fetch FCM tokens:", tokenError);
      return new Response(
        JSON.stringify({ success: true, notificationId: inserted.id, pushSent: false }),
        { status: 200, headers: CORS_HEADERS },
      );
    }

    if (!tokens || tokens.length === 0) {
      return new Response(
        JSON.stringify({ success: true, notificationId: inserted.id, pushSent: false }),
        { status: 200, headers: CORS_HEADERS },
      );
    }

    // Send push to each device
    let accessToken: string;
    try {
      accessToken = await getFcmAccessToken();
    } catch (e) {
      console.error("Failed to get FCM access token:", e);
      return new Response(
        JSON.stringify({ success: true, notificationId: inserted.id, pushSent: false }),
        { status: 200, headers: CORS_HEADERS },
      );
    }

    const staleTokenIds: string[] = [];

    const stringData: Record<string, string> = {};
    if (data) {
      for (const [k, v] of Object.entries(data)) {
        stringData[k] = String(v);
      }
    }
    stringData["type"] = type;
    stringData["notificationId"] = inserted.id;

    await Promise.allSettled(
      tokens.map(async (t: { id: string; token: string }) => {
        try {
          const fcmResponse = await fetch(FCM_URL, {
            method: "POST",
            headers: {
              Authorization: `Bearer ${accessToken}`,
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              message: {
                token: t.token,
                notification: { title, body },
                data: stringData,
              },
            }),
          });

          if (!fcmResponse.ok) {
            const errBody = await fcmResponse.text();
            console.error(`FCM send failed for token ${t.id}:`, errBody);

            if (
              errBody.includes("UNREGISTERED") ||
              errBody.includes("INVALID_ARGUMENT")
            ) {
              staleTokenIds.push(t.id);
            }
          }
        } catch (e) {
          console.error(`FCM send error for token ${t.id}:`, e);
        }
      }),
    );

    // Clean up stale tokens
    if (staleTokenIds.length > 0) {
      const { error: deleteError } = await supabase
        .from("fcm_tokens")
        .delete()
        .in_("id", staleTokenIds);

      if (deleteError) {
        console.error("Failed to delete stale tokens:", deleteError);
      } else {
        console.log(`Cleaned up ${staleTokenIds.length} stale FCM token(s)`);
      }
    }

    return new Response(
      JSON.stringify({
        success: true,
        notificationId: inserted.id,
        pushSent: true,
        deviceCount: tokens.length,
        staleTokensRemoved: staleTokenIds.length,
      }),
      { status: 200, headers: CORS_HEADERS },
    );
  } catch (e) {
    console.error("Unhandled error:", e);
    return new Response(
      JSON.stringify({ error: "Internal server error" }),
      { status: 500, headers: CORS_HEADERS },
    );
  }
});
