import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  cachedPlaceDetails,
  cachedBatchPlaceDetails,
  cachedTextSearch,
  cachedDistanceMatrix,
  cachedTimezone,
  cachedDirections,
  cachedGeocode,
} from "../_shared/cached_google.ts";
import { TTL_PLACE_HERO_METADATA_SECONDS } from "../_shared/google_maps_cache_ttl.ts";
import { redisGet, redisSet } from "../_shared/redis_cache.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const GOOGLE_MAPS_API_KEY = Deno.env.get("GOOGLE_MAPS_API_KEY") ?? "";

const NEW_PLACES_BASE = "https://places.googleapis.com/v1";
const TRIP_DOCUMENTS_BUCKET = "trip-documents";
const PLACE_HERO_MAX_WIDTH_PX = 1200;

async function sha256Hex(input: string): Promise<string> {
  const buf = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(input),
  );
  return Array.from(new Uint8Array(buf))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/** Extract `userId/...` object path from a Storage public object URL (legacy cache / DB rows). */
function storagePathFromTripDocumentsPublicUrl(url: string): string | null {
  const marker = "/object/public/trip-documents/";
  const i = url.indexOf(marker);
  if (i < 0) return null;
  const rest = url.slice(i + marker.length);
  const path = decodeURIComponent(rest.split("?")[0] ?? "").trim();
  return path.length > 0 ? path : null;
}

async function signTripDocumentsHeroUrl(
  admin: ReturnType<typeof createClient>,
  storagePath: string,
): Promise<string | null> {
  const { data, error } = await admin.storage.from(TRIP_DOCUMENTS_BUCKET).createSignedUrl(
    storagePath,
    TTL_PLACE_HERO_METADATA_SECONDS,
  );
  if (error || !data?.signedUrl) {
    console.error("[places-cache] place_hero_photo sign", error?.message ?? "no url");
    return null;
  }
  return data.signedUrl;
}

function formatPhotoAttribution(raw: unknown): string {
  const arr = Array.isArray(raw) ? raw : [];
  const parts: string[] = [];
  for (const x of arr) {
    const o = x as Record<string, unknown>;
    const name = typeof o.displayName === "string" ? o.displayName.trim() : "";
    if (name) parts.push(name);
  }
  if (parts.length === 0) return "Google Maps";
  return `Photo: ${parts.join(", ")}`;
}

/** Separate from global Place Details field mask: only metadata needed for one hero image. */
async function fetchFirstPlacePhotoForHero(placeId: string): Promise<{
  bytes: Uint8Array;
  contentType: string;
  attribution: string;
} | null> {
  if (!GOOGLE_MAPS_API_KEY || !placeId.trim()) return null;

  const metaRes = await fetch(
    `${NEW_PLACES_BASE}/places/${encodeURIComponent(placeId.trim())}`,
    {
      headers: {
        "X-Goog-Api-Key": GOOGLE_MAPS_API_KEY,
        "X-Goog-FieldMask": "id,photos",
      },
    },
  );
  if (!metaRes.ok) return null;

  const meta = await metaRes.json() as {
    photos?: Array<{ name?: string; authorAttributions?: unknown }>;
  };
  const photos = meta.photos;
  if (!Array.isArray(photos) || photos.length === 0) return null;
  const first = photos[0];
  const photoName = first?.name?.trim();
  if (!photoName) return null;

  const attribution = formatPhotoAttribution(first.authorAttributions);

  const mediaUrl =
    `${NEW_PLACES_BASE}/${photoName}/media?maxWidthPx=${PLACE_HERO_MAX_WIDTH_PX}`;
  const mediaRes = await fetch(mediaUrl, {
    headers: { "X-Goog-Api-Key": GOOGLE_MAPS_API_KEY },
    redirect: "follow",
  });
  if (!mediaRes.ok) return null;

  const contentType = mediaRes.headers.get("content-type") || "image/jpeg";
  const buf = new Uint8Array(await mediaRes.arrayBuffer());
  if (buf.length < 64) return null;

  return {
    bytes: buf,
    contentType: contentType.startsWith("image/") ? contentType : "image/jpeg",
    attribution,
  };
}

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

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }

  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }

    const supabaseUser = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: userData, error: userErr } = await supabaseUser.auth.getUser();
    if (userErr || !userData?.user?.id) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }

    const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
    const body = await req.json();
    const action = body.action as string;

    switch (action) {
      case "details": {
        const placeId = body.place_id as string;
        if (!placeId?.trim()) {
          return jsonResponse({ error: "place_id is required" }, 400);
        }
        const sessionTok =
          typeof body.sessionToken === "string" ? body.sessionToken.trim() : "";
        const { data, fromCache } = await cachedPlaceDetails(placeId, admin, {
          skipAiEnrich: true,
          ...(sessionTok ? { autocompleteSessionToken: sessionTok } : {}),
        });
        if (fromCache && data) {
          return jsonResponse({ result: data, _cached_at: data._cached_at ?? new Date().toISOString() });
        }
        return jsonResponse({ result: data });
      }

      case "batch_details": {
        const placeIds = body.place_ids as string[];
        if (!Array.isArray(placeIds) || placeIds.length === 0) {
          return jsonResponse({ error: "place_ids array is required" }, 400);
        }
        if (placeIds.length > 50) {
          return jsonResponse({ error: "max 50 place_ids per batch" }, 400);
        }
        const results = await cachedBatchPlaceDetails(placeIds, admin, { skipAiEnrich: true });
        const out: Record<string, { result: unknown; _cached_at?: string }> = {};
        for (const [id, { data, fromCache }] of Object.entries(results)) {
          if (fromCache && data) {
            out[id] = {
              result: data,
              _cached_at: (data._cached_at as string) ?? new Date().toISOString(),
            };
          } else {
            out[id] = { result: data };
          }
        }
        return jsonResponse({ results: out });
      }

      case "text_search": {
        const query = body.query as string;
        if (!query?.trim()) {
          return jsonResponse({ error: "query is required" }, 400);
        }
        const location = body.lat != null && body.lng != null
          ? { lat: body.lat as number, lng: body.lng as number }
          : undefined;
        const { results, fromCache } = await cachedTextSearch(
          query,
          location,
          body.radius as number | undefined,
          body.type as string | undefined,
        );
        if (fromCache) {
          return jsonResponse({ results, _cached_at: new Date().toISOString() });
        }
        return jsonResponse({ results });
      }

      case "distance_matrix": {
        const from = body.from as { lat: number; lng: number } | undefined;
        const to = body.to as { lat: number; lng: number } | undefined;
        if (!from || !to) {
          return jsonResponse({ error: "from and to are required" }, 400);
        }
        const { minutes, fromCache } = await cachedDistanceMatrix(
          from,
          to,
          body.mode as string | undefined,
        );
        return jsonResponse({ minutes, _from_cache: fromCache });
      }

      case "timezone": {
        const lat = body.lat as number;
        const lng = body.lng as number;
        if (lat == null || lng == null) {
          return jsonResponse({ error: "lat and lng are required" }, 400);
        }
        const { timeZoneId, fromCache } = await cachedTimezone(lat, lng);
        return jsonResponse({ timeZoneId, _from_cache: fromCache });
      }

      case "directions": {
        const origin = body.origin as { lat: number; lng: number } | undefined;
        const dest = body.destination as { lat: number; lng: number } | undefined;
        if (!origin || !dest) {
          return jsonResponse({ error: "origin and destination are required" }, 400);
        }
        const { encodedPolyline, durationSeconds, distanceMeters, fromCache } =
          await cachedDirections(
            origin,
            dest,
            body.mode as string | undefined,
          );
        return jsonResponse({
          encodedPolyline,
          durationSeconds,
          distanceMeters,
          _from_cache: fromCache,
        });
      }

      case "geocode": {
        const address = body.address as string;
        if (!address?.trim()) {
          return jsonResponse({ error: "address is required" }, 400);
        }
        const { result, fromCache } = await cachedGeocode(address);
        return jsonResponse({ result, _from_cache: fromCache });
      }

      case "autocomplete": {
        const input = body.input as string;
        if (!input?.trim()) {
          return jsonResponse({ error: "input is required" }, 400);
        }
        if (!GOOGLE_MAPS_API_KEY) {
          return jsonResponse({ suggestions: [] });
        }

        const reqBody: Record<string, unknown> = { input: input.trim() };

        const includedPrimaryTypes = body.includedPrimaryTypes;
        if (Array.isArray(includedPrimaryTypes) && includedPrimaryTypes.length > 0) {
          reqBody.includedPrimaryTypes = includedPrimaryTypes;
        }
        if (typeof body.sessionToken === "string" && body.sessionToken.trim()) {
          reqBody.sessionToken = body.sessionToken.trim();
        }
        if (typeof body.languageCode === "string" && body.languageCode.trim()) {
          reqBody.languageCode = body.languageCode.trim();
        }
        if (typeof body.regionCode === "string" && body.regionCode.trim()) {
          reqBody.regionCode = body.regionCode.trim();
        }
        if (body.locationBias && typeof body.locationBias === "object") {
          reqBody.locationBias = body.locationBias;
        }

        const res = await fetch(
          "https://places.googleapis.com/v1/places:autocomplete",
          {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              "X-Goog-Api-Key": GOOGLE_MAPS_API_KEY,
            },
            body: JSON.stringify(reqBody),
          },
        );

        if (!res.ok) {
          console.error("[places-cache] autocomplete HTTP", res.status, await res.text());
          return jsonResponse({ suggestions: [] });
        }

        const data = await res.json();
        return jsonResponse(data);
      }

      case "place_hero_photo": {
        const placeId = String(body.place_id ?? "").trim();
        const activityId = String(body.activity_id ?? "").trim();
        const tripId = String(body.trip_id ?? "").trim();
        if (!placeId || !activityId || !tripId) {
          return jsonResponse(
            { error: "place_id, activity_id, and trip_id are required" },
            400,
          );
        }

        const { data: isMember, error: memberRpcErr } = await admin.rpc(
          "is_trip_member",
          {
            p_trip_id: tripId,
            p_user_id: userData.user.id,
          },
        );
        if (memberRpcErr) {
          console.error("[places-cache] is_trip_member", memberRpcErr.message);
          return jsonResponse({ error: "member_check_failed" }, 500);
        }
        if (!isMember) {
          return jsonResponse({ error: "Forbidden" }, 403);
        }

        const { data: actRow, error: actErr } = await admin
          .from("trip_activities")
          .select("id")
          .eq("id", activityId)
          .eq("trip_id", tripId)
          .maybeSingle();
        if (actErr || !actRow) {
          return jsonResponse({ error: "Activity not found" }, 404);
        }

        const cacheKey = `place_hero_photo:${placeId}:w${PLACE_HERO_MAX_WIDTH_PX}`;
        const cachedRaw = await redisGet(cacheKey);
        if (cachedRaw) {
          try {
            const parsed = JSON.parse(cachedRaw) as Record<string, unknown>;
            if (parsed.v === 2 && typeof parsed.storage_path === "string") {
              const p = parsed.storage_path.trim();
              const attr = typeof parsed.hero_attribution === "string"
                ? parsed.hero_attribution.trim()
                : "";
              if (p) {
                const signed = await signTripDocumentsHeroUrl(admin, p);
                if (signed) {
                  return jsonResponse({
                    hero_image_url: signed,
                    hero_attribution: attr,
                  });
                }
              }
            }
            const legacyUrl = typeof parsed.hero_image_url === "string"
              ? parsed.hero_image_url.trim()
              : "";
            if (legacyUrl) {
              const legacyPath = storagePathFromTripDocumentsPublicUrl(legacyUrl);
              if (legacyPath) {
                const signed = await signTripDocumentsHeroUrl(admin, legacyPath);
                if (signed) {
                  const attr = typeof parsed.hero_attribution === "string"
                    ? parsed.hero_attribution.trim()
                    : "";
                  redisSet(
                    cacheKey,
                    JSON.stringify({
                      v: 2,
                      storage_path: legacyPath,
                      hero_attribution: attr,
                    }),
                    TTL_PLACE_HERO_METADATA_SECONDS,
                  );
                  return jsonResponse({
                    hero_image_url: signed,
                    hero_attribution: attr,
                  });
                }
              }
            }
          } catch { /* refetch */ }
        }

        // Any trip member may trigger the first hero fetch; Redis + Storage dedupe by place id.
        const hero = await fetchFirstPlacePhotoForHero(placeId);
        if (!hero) {
          return jsonResponse({ hero_image_url: null, hero_attribution: null });
        }

        const hash = await sha256Hex(placeId);
        const storagePath =
          `${userData.user.id}/trip-documents/${tripId}/place-heroes/${hash}/w${PLACE_HERO_MAX_WIDTH_PX}.jpg`;

        const { error: upErr } = await admin.storage.from(TRIP_DOCUMENTS_BUCKET).upload(
          storagePath,
          hero.bytes,
          {
            contentType: hero.contentType,
            upsert: true,
          },
        );
        if (upErr) {
          console.error("[places-cache] place_hero_photo upload", upErr.message);
          return jsonResponse({ error: "upload_failed" }, 500);
        }

        const signedUrl = await signTripDocumentsHeroUrl(admin, storagePath);
        if (!signedUrl) {
          return jsonResponse({ error: "sign_failed" }, 500);
        }
        const meta = {
          v: 2 as const,
          storage_path: storagePath,
          hero_attribution: hero.attribution,
        };
        redisSet(cacheKey, JSON.stringify(meta), TTL_PLACE_HERO_METADATA_SECONDS);
        return jsonResponse({
          hero_image_url: signedUrl,
          hero_attribution: hero.attribution,
        });
      }

      default:
        return jsonResponse({ error: `Unknown action: ${action}` }, 400);
    }
  } catch (e) {
    console.error("[places-cache]", e);
    return jsonResponse(
      { error: e instanceof Error ? e.message : "Internal error" },
      500,
    );
  }
});
