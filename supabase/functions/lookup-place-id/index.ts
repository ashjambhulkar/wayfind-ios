// Phase C.2 — `lookup-place-id` Edge Function.
//
// Takes an Apple/MapKit hit (name + lat/lng) and resolves it to a Google
// place_id via a 3-tier ladder, ordered cheapest-first:
//
//   1. `city_places` spatial+fuzzy match  → free, leverages owned data.
//   2. `place_id_bridge` cache             → free after first resolve.
//   3. Google Text Search Essentials       → cheapest Google SKU; field
//                                            mask is hard-coded to `places.id`.
//
// Confidence ladder (returned to iOS as `resolution`):
//   ≥ 0.85   → `single`     — auto-commit
//   0.50-.85 → `ambiguous`  — return up to 3 candidates, iOS shows half-sheet
//   < 0.50   → `miss`       — fall through to "save as Apple-only" UX
//
// Auth: anonymous JWT required (Supabase enforces it via verify_jwt = true in
// supabase/config.toml — see below). Per-user 60/hr + per-IP 600/hr Upstash
// sliding-window rate limit so a single user cannot blow our Google quota.
//
// Cost guardrail: Google call is *only* tier 3, and only fires when both
// owned-data tiers miss. The Text Search field mask `places.id` is the
// cheapest Places API (New) request shape that returns a place_id.

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { Ratelimit } from "https://esm.sh/@upstash/ratelimit@1.0.1";
import { Redis } from "https://esm.sh/@upstash/redis@1.28.4";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const GOOGLE_MAPS_API_KEY = Deno.env.get("GOOGLE_MAPS_API_KEY") ?? "";
const UPSTASH_REDIS_REST_URL = Deno.env.get("UPSTASH_REDIS_REST_URL") ?? "";
const UPSTASH_REDIS_REST_TOKEN = Deno.env.get("UPSTASH_REDIS_REST_TOKEN") ?? "";

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

// ── Rate limiters ──
//
// Two independent limiters: per-user (cheaper budget, harder cap) and per-IP
// (safety net for unauthenticated abuse paths). Both use Upstash sliding
// window for accurate burst control. Ratelimiter is created lazily per
// request so the Deno isolate doesn't crash when env vars are missing
// (e.g. local dev without Upstash).
let cachedLimiterUser: Ratelimit | null = null;
let cachedLimiterIp: Ratelimit | null = null;
function getLimiters(): { user: Ratelimit; ip: Ratelimit } | null {
  if (!UPSTASH_REDIS_REST_URL || !UPSTASH_REDIS_REST_TOKEN) return null;
  if (!cachedLimiterUser || !cachedLimiterIp) {
    const redis = new Redis({
      url: UPSTASH_REDIS_REST_URL,
      token: UPSTASH_REDIS_REST_TOKEN,
    });
    cachedLimiterUser = new Ratelimit({
      redis,
      limiter: Ratelimit.slidingWindow(60, "1 h"),
      prefix: "rl:lookup-place-id:user",
      analytics: false,
    });
    cachedLimiterIp = new Ratelimit({
      redis,
      limiter: Ratelimit.slidingWindow(600, "1 h"),
      prefix: "rl:lookup-place-id:ip",
      analytics: false,
    });
  }
  return { user: cachedLimiterUser, ip: cachedLimiterIp };
}

// ── Confidence scoring ──

const SPATIAL_RADIUS_METERS = 75; // tight: catches Apple/Google ~30m drift
const SPATIAL_RADIUS_FAR_METERS = 250; // loose: low-confidence candidates

interface Candidate {
  place_id: string;
  name: string;
  lat: number;
  lng: number;
  distance_m: number;
  /** 0–1 trigram similarity. */
  name_sim: number;
}

/**
 * Combines distance + name similarity into a single 0..1 score.
 * Distance contribution is bell-curved around 0m (penalises >100m hard).
 * Name similarity is the Postgres trigram similarity (0..1) returned by
 * `similarity()`. Final score weights distance 60%, name 40% — distance is
 * the more reliable signal because Apple's coords are usually within 50m
 * even when its name is spelled differently from Google's.
 */
function score(c: Candidate): number {
  const distComponent = Math.exp(-Math.pow(c.distance_m / 60, 2));
  return 0.6 * distComponent + 0.4 * c.name_sim;
}

interface RankedCandidate extends Candidate {
  score: number;
}

function rank(candidates: Candidate[]): RankedCandidate[] {
  return candidates
    .map((c) => ({ ...c, score: score(c) }))
    .sort((a, b) => b.score - a.score);
}

// ── Tier 1: city_places spatial + fuzzy ──

async function tier1CityPlaces(
  supabase: ReturnType<typeof createClient>,
  lat: number,
  lng: number,
  name: string,
): Promise<RankedCandidate[]> {
  // Single SQL: ST_DWithin on the generated `geom` column + similarity() on
  // name. Returns up to 5 closest within `SPATIAL_RADIUS_FAR_METERS`, the
  // edge function then ranks by combined score.
  const { data, error } = await supabase.rpc("lookup_place_id_city_places", {
    p_lat: lat,
    p_lng: lng,
    p_name: name,
    p_radius_m: SPATIAL_RADIUS_FAR_METERS,
    p_limit: 5,
  });
  if (error || !data) return [];
  return rank(
    (data as Array<Record<string, unknown>>).map((row) => ({
      place_id: String(row.place_id),
      name: String(row.name),
      lat: Number(row.lat),
      lng: Number(row.lng),
      distance_m: Number(row.distance_m),
      name_sim: Number(row.name_sim),
    })),
  );
}

// ── Tier 2: place_id_bridge cache ──

async function tier2BridgeCache(
  supabase: ReturnType<typeof createClient>,
  lat: number,
  lng: number,
  name: string,
): Promise<RankedCandidate[]> {
  const { data, error } = await supabase.rpc("lookup_place_id_bridge", {
    p_lat: lat,
    p_lng: lng,
    p_name: name,
    p_radius_m: SPATIAL_RADIUS_FAR_METERS,
    p_limit: 5,
  });
  if (error || !data) return [];
  return rank(
    (data as Array<Record<string, unknown>>).map((row) => ({
      place_id: String(row.place_id),
      name: String(row.name),
      lat: Number(row.lat),
      lng: Number(row.lng),
      distance_m: Number(row.distance_m),
      name_sim: Number(row.name_sim),
    })),
  );
}

// ── Tier 3: Google Text Search Essentials (places.id only) ──

async function tier3GoogleTextSearch(
  query: string,
  lat: number,
  lng: number,
): Promise<{ place_id: string; name: string; lat: number; lng: number } | null> {
  if (!GOOGLE_MAPS_API_KEY) return null;
  // Field mask is the cost-control knob — `places.id` alone is the
  // cheapest "Essentials" SKU. We additionally request displayName +
  // location so the bridge cache row carries something useful, but those
  // are still inside the Essentials tier.
  const fieldMask = "places.id,places.displayName,places.location";
  const body = {
    textQuery: query,
    maxResultCount: 1,
    locationBias: {
      circle: { center: { latitude: lat, longitude: lng }, radius: 250.0 },
    },
  };
  const res = await fetch("https://places.googleapis.com/v1/places:searchText", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Goog-Api-Key": GOOGLE_MAPS_API_KEY,
      "X-Goog-FieldMask": fieldMask,
    },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    console.warn(`[lookup-place-id] Google text search failed: ${res.status}`);
    return null;
  }
  const data = await res.json();
  const hit = (data?.places ?? [])[0];
  if (!hit?.id) return null;
  return {
    place_id: String(hit.id),
    name: String(hit.displayName?.text ?? query),
    lat: Number(hit.location?.latitude ?? lat),
    lng: Number(hit.location?.longitude ?? lng),
  };
}

// ── Bridge writeback ──

async function writeBridge(
  supabase: ReturnType<typeof createClient>,
  args: {
    lat: number;
    lng: number;
    name: string;
    place_id: string;
    source: "city_places" | "google_text_search" | "manual";
    confidence: number;
    city_profile_id: string | null;
  },
): Promise<void> {
  const { error } = await supabase.from("place_id_bridge").insert({
    lat: args.lat,
    lng: args.lng,
    name: args.name,
    place_id: args.place_id,
    source: args.source,
    confidence: args.confidence,
    city_profile_id: args.city_profile_id,
  });
  if (error) {
    // Non-fatal — caching is best-effort.
    console.warn(`[lookup-place-id] bridge writeback failed: ${error.message}`);
  }
}

// ── Resolution ──

interface ResolveBody {
  name?: unknown;
  lat?: unknown;
  lng?: unknown;
  city_profile_id?: unknown;
}

interface ResolveCandidate {
  place_id: string;
  name: string;
  lat: number;
  lng: number;
  confidence: number;
  source: "city_places" | "place_id_bridge" | "google_text_search";
}

interface ResolveResponse {
  resolution: "single" | "ambiguous" | "miss";
  candidates: ResolveCandidate[];
}

const SINGLE_THRESHOLD = 0.85;
const AMBIGUOUS_THRESHOLD = 0.5;

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS_HEADERS });
  if (req.method !== "POST") return jsonResponse({ error: "method_not_allowed" }, 405);

  // ── Auth: must have a JWT (Supabase verifies it before invoking us when
  // verify_jwt = true). We additionally pull the user id for per-user
  // rate limiting. ──
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
  const userId = userData.user.id;

  // ── Rate limit: per-user 60/hr, per-IP 600/hr. Soft fail (allow) when
  // Upstash isn't configured — local dev path. ──
  const limiters = getLimiters();
  if (limiters) {
    const ip =
      req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ||
      req.headers.get("x-real-ip") ||
      "unknown";
    const [userRl, ipRl] = await Promise.all([
      limiters.user.limit(userId),
      limiters.ip.limit(ip),
    ]);
    if (!userRl.success || !ipRl.success) {
      return jsonResponse(
        {
          error: "rate_limited",
          retry_after_ms: Math.max(
            userRl.success ? 0 : userRl.reset - Date.now(),
            ipRl.success ? 0 : ipRl.reset - Date.now(),
          ),
        },
        429,
      );
    }
  }

  // ── Body ──
  let body: ResolveBody;
  try {
    body = (await req.json()) as ResolveBody;
  } catch {
    return jsonResponse({ error: "invalid_json" }, 400);
  }
  const name = typeof body.name === "string" ? body.name.trim() : "";
  const lat = Number(body.lat);
  const lng = Number(body.lng);
  const cityProfileId = typeof body.city_profile_id === "string"
    ? body.city_profile_id
    : null;
  if (!name || !Number.isFinite(lat) || !Number.isFinite(lng)) {
    return jsonResponse({ error: "missing_or_invalid_fields" }, 400);
  }

  // Service-role client for owned-data lookups + bridge writeback (RLS
  // forbids anon writes to `place_id_bridge`).
  const sr = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });

  // ── Tier 1 ──
  const tier1 = await tier1CityPlaces(sr, lat, lng, name);
  const t1Top = tier1[0];
  if (t1Top && t1Top.score >= SINGLE_THRESHOLD) {
    const resp: ResolveResponse = {
      resolution: "single",
      candidates: [
        {
          place_id: t1Top.place_id,
          name: t1Top.name,
          lat: t1Top.lat,
          lng: t1Top.lng,
          confidence: t1Top.score,
          source: "city_places",
        },
      ],
    };
    // Cache the high-confidence resolution so the next caller hits tier 2.
    await writeBridge(sr, {
      lat,
      lng,
      name,
      place_id: t1Top.place_id,
      source: "city_places",
      confidence: t1Top.score,
      city_profile_id: cityProfileId,
    });
    return jsonResponse(resp);
  }

  // ── Tier 2 ──
  const tier2 = await tier2BridgeCache(sr, lat, lng, name);
  const t2Top = tier2[0];
  if (t2Top && t2Top.score >= SINGLE_THRESHOLD) {
    const resp: ResolveResponse = {
      resolution: "single",
      candidates: [
        {
          place_id: t2Top.place_id,
          name: t2Top.name,
          lat: t2Top.lat,
          lng: t2Top.lng,
          confidence: t2Top.score,
          source: "place_id_bridge",
        },
      ],
    };
    return jsonResponse(resp);
  }

  // ── Tier 3 (Google) ──
  const t3 = await tier3GoogleTextSearch(name, lat, lng);
  if (t3) {
    // Compute confidence using the same scorer. Distance is from the
    // Apple input to Google's reported location.
    const dx = (t3.lat - lat) * 111_320;
    const dy = (t3.lng - lng) * 111_320 * Math.cos((lat * Math.PI) / 180);
    const distance_m = Math.sqrt(dx * dx + dy * dy);
    // Trigram-style approximation client-side for confidence; the bridge
    // row stores the exact (Apple-vs-Google) name pair so Tier 2 can
    // re-derive on next call.
    const lcA = name.toLowerCase();
    const lcB = t3.name.toLowerCase();
    const name_sim = lcA === lcB ? 1.0 : lcB.includes(lcA) || lcA.includes(lcB) ? 0.85 : 0.6;
    const conf = score({
      place_id: t3.place_id,
      name: t3.name,
      lat: t3.lat,
      lng: t3.lng,
      distance_m,
      name_sim,
    });
    await writeBridge(sr, {
      lat,
      lng,
      name,
      place_id: t3.place_id,
      source: "google_text_search",
      confidence: conf,
      city_profile_id: cityProfileId,
    });
    if (conf >= SINGLE_THRESHOLD) {
      return jsonResponse({
        resolution: "single",
        candidates: [{
          place_id: t3.place_id,
          name: t3.name,
          lat: t3.lat,
          lng: t3.lng,
          confidence: conf,
          source: "google_text_search",
        }],
      } satisfies ResolveResponse);
    }
    if (conf >= AMBIGUOUS_THRESHOLD) {
      // Combine Google hit with any tier-1/tier-2 partial matches for the
      // user to disambiguate.
      const combined: ResolveCandidate[] = [
        {
          place_id: t3.place_id,
          name: t3.name,
          lat: t3.lat,
          lng: t3.lng,
          confidence: conf,
          source: "google_text_search",
        },
        ...tier1.slice(0, 2).map((c) => ({
          place_id: c.place_id,
          name: c.name,
          lat: c.lat,
          lng: c.lng,
          confidence: c.score,
          source: "city_places" as const,
        })),
      ];
      return jsonResponse({
        resolution: "ambiguous",
        candidates: combined.slice(0, 3),
      } satisfies ResolveResponse);
    }
  }

  // ── Total miss — return tier 1/tier 2 partial matches as ambiguous if
  // we have any usable signal at all, otherwise a clean miss. ──
  const combined = [...tier1, ...tier2]
    .filter((c) => c.score >= AMBIGUOUS_THRESHOLD)
    .slice(0, 3);
  if (combined.length > 0) {
    return jsonResponse({
      resolution: "ambiguous",
      candidates: combined.map((c, idx) => ({
        place_id: c.place_id,
        name: c.name,
        lat: c.lat,
        lng: c.lng,
        confidence: c.score,
        source: idx < tier1.length ? "city_places" : "place_id_bridge",
      })),
    } satisfies ResolveResponse);
  }
  return jsonResponse({ resolution: "miss", candidates: [] } satisfies ResolveResponse);
});
