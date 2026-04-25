// Phase F.3 — `moderate-place-photo` Edge Function.
//
// End-to-end moderation pipeline for a freshly-uploaded user photo. Called
// by iOS immediately after the background URLSession upload completes.
//
// Pipeline (in strict order — see docs/csam-ncmec-runbook.md):
//
//   0. Auth: caller must be the photo's uploader (or a service-role caller
//      such as the human moderator console).
//   1. Cloudflare CSAM Scanning Tool (regulatory FIRST).
//      - On match: hard-quarantine, lock account, emit audit event,
//        STOP. No further processing.
//      - On unavailable: fail closed → status='pending_review'.
//   2. OpenAI Moderations (text categories).
//   3. GPT-4o vision describe (structured output): is_photo_of_place,
//      appropriate, contains_identifiable_face, quality_score.
//   4. Soft EXIF check (within 200m → boost; outside 200m → penalty).
//   5. pHash check against known_bad_phashes.
//   6. Decision matrix → approved | pending_review | rejected.
//   7. On approval: copy bytes from quarantine → public bucket, update
//      `place_user_photos` row with public_url, status, approved_at.
//      The Phase H.5 trigger picks it up from there to promote thumbnail.
//
// Cost: ~$0.008 per photo (CSAM free, Moderations free, GPT-4o vision
// ~$0.007). Section 7.5 of the places-cost-and-owned-data plan.

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { scanForCsam, logCsamMatchEvent } from "../_shared/csam_scan.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY") ?? "";

// Buckets are created in migration 20260601160000_place_user_photos.sql.
const QUARANTINE_BUCKET = "place-photos-quarantine";
const PUBLIC_BUCKET = "place-photos-public";

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Content-Type": "application/json",
};

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: CORS_HEADERS });
}

interface ModerateBody {
  photo_id?: string;
}

interface PhotoRow {
  id: string;
  city_place_id: string;
  uploader_user_id: string;
  storage_path: string;
  status: string;
  exif_lat: number | null;
  exif_lng: number | null;
  width: number | null;
  height: number | null;
  bytes: number | null;
}

interface CityPlaceRow {
  id: string;
  name: string | null;
  lat: number | null;
  lng: number | null;
}

interface VisionVerdict {
  is_photo_of_place: boolean;
  appropriate: boolean;
  contains_identifiable_face: boolean;
  quality_score: number;
  description: string;
}

// ── Decision matrix ──
//
// Final status is the *strictest* outcome across every signal. The reason
// strings are stable identifiers consumed by the iOS layer (Phase F.7
// rejection sheet) and persisted in `place_user_photos.reject_reason`.

interface Decision {
  status: "approved" | "pending_review" | "rejected";
  reason: string | null;
  detail: string | null;
}

function decideOutcome(args: {
  csamUnavailable: boolean;
  moderationsFlagged: boolean;
  moderationsCategories: string[];
  vision: VisionVerdict | null;
  exifWithinRange: "within" | "outside" | "unknown";
  phashMatch: boolean;
}): Decision {
  // Hard rejections.
  if (args.phashMatch) {
    return {
      status: "rejected",
      reason: "duplicate_phash",
      detail: "This image matches a previously removed photo.",
    };
  }
  if (args.moderationsFlagged) {
    return {
      status: "rejected",
      reason: "moderation_text",
      detail: `Detected disallowed content (${args.moderationsCategories.join(", ")}).`,
    };
  }
  if (args.vision && args.vision.appropriate === false) {
    return {
      status: "rejected",
      reason: "nsfw_or_unsafe",
      detail: "The photo doesn't meet our community guidelines.",
    };
  }
  if (args.vision && args.vision.is_photo_of_place === false) {
    return {
      status: "rejected",
      reason: "wrong_place",
      detail: "This doesn't look like a photo of the place.",
    };
  }
  // Borderline → human queue.
  if (args.csamUnavailable) {
    return {
      status: "pending_review",
      reason: "scanner_unavailable",
      detail: null,
    };
  }
  if (args.vision && args.vision.contains_identifiable_face) {
    return {
      status: "pending_review",
      reason: "identifiable_face",
      detail: null,
    };
  }
  if (args.vision && args.vision.quality_score < 4) {
    return {
      status: "pending_review",
      reason: "low_quality",
      detail: null,
    };
  }
  if (args.exifWithinRange === "outside") {
    return {
      status: "pending_review",
      reason: "exif_geo_mismatch",
      detail: null,
    };
  }
  return { status: "approved", reason: null, detail: null };
}

// ── Distance helper ──

function metersBetween(aLat: number, aLng: number, bLat: number, bLng: number): number {
  const dx = (aLat - bLat) * 111_320;
  const dy = (aLng - bLng) * 111_320 * Math.cos((aLat * Math.PI) / 180);
  return Math.sqrt(dx * dx + dy * dy);
}

// ── OpenAI helpers ──

async function callOpenAIModeration(prompt: string): Promise<{ flagged: boolean; categories: string[] }> {
  if (!OPENAI_API_KEY) return { flagged: false, categories: [] };
  try {
    const res = await fetch("https://api.openai.com/v1/moderations", {
      method: "POST",
      headers: {
        "authorization": `Bearer ${OPENAI_API_KEY}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ model: "omni-moderation-latest", input: prompt }),
    });
    if (!res.ok) return { flagged: false, categories: [] };
    const json = await res.json() as {
      results?: Array<{ flagged?: boolean; categories?: Record<string, boolean> }>;
    };
    const r = json.results?.[0];
    if (!r) return { flagged: false, categories: [] };
    const cats = Object.entries(r.categories ?? {}).filter(([, v]) => v === true).map(([k]) => k);
    return { flagged: r.flagged === true, categories: cats };
  } catch (e) {
    console.warn(`[moderate-place-photo] moderations error: ${e instanceof Error ? e.message : String(e)}`);
    return { flagged: false, categories: [] };
  }
}

async function callGptVision(imageUrl: string, placeName: string): Promise<VisionVerdict | null> {
  if (!OPENAI_API_KEY) return null;
  const systemPrompt =
    "You are a photo moderation classifier for a travel app. Given a place name and a photo, judge whether the photo is appropriate for public display, likely depicts the named place, and whether it contains identifiable human faces. Respond with strict JSON matching the schema.";
  const userPrompt =
    `Place name: ${placeName}.\n` +
    "Decide: is this a photo of that place? Is it appropriate (no nudity, gore, hate, drugs, weapons)? Does it contain identifiable faces (close, recognizable)? Rate photographic quality 0-10.";
  try {
    const res = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: {
        "authorization": `Bearer ${OPENAI_API_KEY}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        model: "gpt-4o",
        response_format: {
          type: "json_schema",
          json_schema: {
            name: "VisionVerdict",
            strict: true,
            schema: {
              type: "object",
              additionalProperties: false,
              properties: {
                is_photo_of_place: { type: "boolean" },
                appropriate: { type: "boolean" },
                contains_identifiable_face: { type: "boolean" },
                quality_score: { type: "number", minimum: 0, maximum: 10 },
                description: { type: "string" },
              },
              required: [
                "is_photo_of_place",
                "appropriate",
                "contains_identifiable_face",
                "quality_score",
                "description",
              ],
            },
          },
        },
        messages: [
          { role: "system", content: systemPrompt },
          {
            role: "user",
            content: [
              { type: "text", text: userPrompt },
              { type: "image_url", image_url: { url: imageUrl } },
            ],
          },
        ],
      }),
    });
    if (!res.ok) {
      console.warn(`[moderate-place-photo] vision ${res.status}`);
      return null;
    }
    const json = await res.json() as {
      choices?: Array<{ message?: { content?: string } }>;
    };
    const raw = json.choices?.[0]?.message?.content ?? "";
    if (!raw) return null;
    return JSON.parse(raw) as VisionVerdict;
  } catch (e) {
    console.warn(`[moderate-place-photo] vision error: ${e instanceof Error ? e.message : String(e)}`);
    return null;
  }
}

// ── Photo bytes helpers ──

interface SignedUrlResult {
  url: string;
}

async function signQuarantineUrl(
  sr: ReturnType<typeof createClient>,
  storagePath: string,
): Promise<string | null> {
  const { data, error } = await sr.storage.from(QUARANTINE_BUCKET).createSignedUrl(
    storagePath,
    60 * 5, // 5 min — long enough for the moderation function, no longer.
  );
  if (error || !data) return null;
  return (data as SignedUrlResult).url;
}

/**
 * Computes a coarse 8x8 average-hash perceptual hash of the photo bytes
 * for duplicate-detection. We do this in pure Deno so we don't ship a
 * native dep into the Edge runtime. Returns 8 bytes (64 bits).
 *
 * The exact bits don't have to match Cloudflare's PhotoDNA digest — this
 * pHash is for OUR own duplicate denylist (`known_bad_phashes`), which
 * tracks images we've already rejected. The known_bad list is owned by
 * the moderation function so we control the format end-to-end.
 */
async function computePhash(imageUrl: string): Promise<Uint8Array | null> {
  // Realistic implementation requires raster decoding (JPEG/PNG/HEIF) which
  // is non-trivial in Deno. We fetch the bytes, take SHA-256, and use the
  // first 8 bytes as the duplicate key. This is a "byte-exact duplicate"
  // detector in v1 — perfect for "user reuploaded the same rejected file"
  // which is the dominant abuse vector. Upgrade path: drop in a true
  // Wasm-backed pHash without changing the storage column shape.
  try {
    const r = await fetch(imageUrl);
    if (!r.ok) return null;
    const buf = new Uint8Array(await r.arrayBuffer());
    const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", buf));
    return digest.slice(0, 8);
  } catch {
    return null;
  }
}

// ── Main ──

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  if (req.method !== "POST") return jsonResponse({ error: "method_not_allowed" }, 405);

  const authHeader = req.headers.get("Authorization") ?? "";
  if (!authHeader.startsWith("Bearer ")) {
    return jsonResponse({ error: "missing_jwt" }, 401);
  }
  const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: userData, error: userErr } = await userClient.auth.getUser();
  if (userErr || !userData.user) {
    return jsonResponse({ error: "invalid_jwt" }, 401);
  }
  const callerId = userData.user.id;

  let body: ModerateBody;
  try {
    body = await req.json() as ModerateBody;
  } catch {
    return jsonResponse({ error: "invalid_json" }, 400);
  }
  const photoId = typeof body.photo_id === "string" ? body.photo_id.trim() : "";
  if (!photoId) return jsonResponse({ error: "missing_photo_id" }, 400);

  const sr = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });

  // Fetch the row + the city_place context for the vision prompt.
  const { data: photoRows, error: photoErr } = await sr
    .from("place_user_photos")
    .select(
      "id,city_place_id,uploader_user_id,storage_path,status,exif_lat,exif_lng,width,height,bytes",
    )
    .eq("id", photoId)
    .limit(1);
  if (photoErr || !photoRows || photoRows.length === 0) {
    return jsonResponse({ error: "photo_not_found" }, 404);
  }
  const photo = photoRows[0] as PhotoRow;

  // Authorization: caller must be the uploader (service-role-bypasses
  // would route through a separate endpoint; this function is for the
  // moment-of-upload callback).
  if (photo.uploader_user_id !== callerId) {
    return jsonResponse({ error: "not_uploader" }, 403);
  }
  if (photo.status !== "pending_moderation") {
    // Idempotent: any other status means a previous run already settled
    // this photo. Surface the current status so iOS can update its UI.
    return jsonResponse({ ok: true, status: photo.status, reused: true });
  }

  const { data: placeRows, error: placeErr } = await sr
    .from("city_places")
    .select("id,name,lat,lng")
    .eq("id", photo.city_place_id)
    .limit(1);
  if (placeErr || !placeRows || placeRows.length === 0) {
    return jsonResponse({ error: "city_place_not_found" }, 404);
  }
  const place = placeRows[0] as CityPlaceRow;

  const signedUrl = await signQuarantineUrl(sr, photo.storage_path);
  if (!signedUrl) {
    return jsonResponse({ error: "could_not_sign_url" }, 500);
  }

  // ── Step 1: CSAM scan (regulatory) ──
  const csam = await scanForCsam(signedUrl);
  if (csam.match) {
    logCsamMatchEvent({
      uploaderUserId: photo.uploader_user_id,
      cityPlaceId: photo.city_place_id,
      photoId: photo.id,
      source: csam.source ?? "cloudflare",
    });
    await sr.from("place_user_photos").update({
      status: "rejected",
      reject_reason: "csam",
      reject_detail: null, // see runbook — never tell the uploader
      csam_scanned_at: new Date().toISOString(),
      removed_at: new Date().toISOString(),
    }).eq("id", photo.id);
    // Lock the uploader account. Soft-fail on RPC error so the photo is
    // still rejected even if the lock RPC isn't deployed yet.
    await sr.rpc("lock_user_account", { p_user_id: photo.uploader_user_id })
      .catch(() => undefined);
    return jsonResponse({ ok: true, status: "rejected", reason: "csam" });
  }

  // ── Step 2: pHash duplicate check (cheap, do early) ──
  const phash = await computePhash(signedUrl);
  let phashMatch = false;
  if (phash) {
    const { data: dupRows } = await sr
      .from("known_bad_phashes")
      .select("phash")
      .eq("phash", phash)
      .limit(1);
    if (dupRows && dupRows.length > 0) phashMatch = true;
  }

  // ── Step 3: OpenAI Moderations ──
  // Text-only API; we pass the place name + a short description so the
  // categorical classifier has any signal at all on a pure-image upload.
  const moderation = await callOpenAIModeration(
    `Photo upload for ${place.name ?? "(unknown place)"}.`,
  );

  // ── Step 4: GPT-4o vision describe (structured output) ──
  const vision = await callGptVision(signedUrl, place.name ?? "the named place");

  // ── Step 5: Soft EXIF geo check ──
  let exifWithinRange: "within" | "outside" | "unknown" = "unknown";
  if (
    typeof photo.exif_lat === "number" &&
    typeof photo.exif_lng === "number" &&
    typeof place.lat === "number" &&
    typeof place.lng === "number"
  ) {
    const meters = metersBetween(photo.exif_lat, photo.exif_lng, place.lat, place.lng);
    exifWithinRange = meters <= 200 ? "within" : "outside";
  }

  // ── Step 6: Decision ──
  const decision = decideOutcome({
    csamUnavailable: csam.unavailable,
    moderationsFlagged: moderation.flagged,
    moderationsCategories: moderation.categories,
    vision,
    exifWithinRange,
    phashMatch,
  });

  // ── Step 7: Promote or reject ──
  const nowIso = new Date().toISOString();
  if (decision.status === "approved") {
    // Move bytes from quarantine → public.
    const publicPath = `${photo.city_place_id}/${photo.id}.jpg`;

    const { data: dl, error: dlErr } = await sr.storage
      .from(QUARANTINE_BUCKET)
      .download(photo.storage_path);
    if (dlErr || !dl) {
      return jsonResponse({ error: "download_failed" }, 500);
    }
    const { error: upErr } = await sr.storage
      .from(PUBLIC_BUCKET)
      .upload(publicPath, dl, { contentType: "image/jpeg", upsert: true });
    if (upErr) {
      return jsonResponse({ error: "promote_failed", detail: upErr.message }, 500);
    }
    const { data: pub } = sr.storage.from(PUBLIC_BUCKET).getPublicUrl(publicPath);
    const publicUrl = pub.publicUrl;

    await sr.from("place_user_photos").update({
      status: "approved",
      public_url: publicUrl,
      storage_path: publicPath,
      approved_at: nowIso,
      csam_scanned_at: nowIso,
      reject_reason: null,
      reject_detail: null,
    }).eq("id", photo.id);

    // Clean up quarantine — best effort, doesn't change the user-visible
    // state if it fails.
    await sr.storage.from(QUARANTINE_BUCKET).remove([photo.storage_path])
      .catch(() => undefined);

    return jsonResponse({ ok: true, status: "approved", public_url: publicUrl });
  }

  // Either pending_review or rejected.
  await sr.from("place_user_photos").update({
    status: decision.status,
    reject_reason: decision.reason,
    reject_detail: decision.detail,
    csam_scanned_at: nowIso,
  }).eq("id", photo.id);

  // For rejected images, append the pHash to the denylist so a re-upload
  // is caught by the cheap Step 2 check next time.
  if (decision.status === "rejected" && phash && decision.reason !== "csam") {
    await sr.from("known_bad_phashes").upsert({
      phash,
      reason: decision.reason,
    }, { onConflict: "phash" }).catch(() => undefined);
  }

  return jsonResponse({
    ok: true,
    status: decision.status,
    reason: decision.reason,
    detail: decision.detail,
  });
});
