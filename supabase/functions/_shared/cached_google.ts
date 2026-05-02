import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  TTL_GEOCODE_SECONDS,
  TTL_PLACE_DETAILS_SECONDS,
  TTL_ROUTES_DIRECTIONS_SECONDS,
  TTL_TEXT_SEARCH_DAY_PLAN_SECONDS,
  TTL_TEXT_SEARCH_SECONDS,
  TTL_TIMEZONE_SECONDS,
} from "./google_maps_cache_ttl.ts";
import { redisGet, redisSet, redisPipelineGet } from "./redis_cache.ts";
import {
  cityPoolOpeningHoursToGoogleOpeningHours,
  collectHttpsPhotoUrlsFromCityPlaceImages,
} from "./city_places_pool.ts";
import { enrichPlaceWithAI, type PlaceAiContent } from "./place_ai_enrich.ts";

const GOOGLE_MAPS_API_KEY = Deno.env.get("GOOGLE_MAPS_API_KEY") ?? "";

const NEW_PLACES_BASE = "https://places.googleapis.com/v1";

/**
 * Minimal Place Details (New) — essentials only. No rating, hours, photos, reviews, phones, or website.
 * Rich UX (one hero image) uses `places-cache` `place_hero_photo` with `id,photos` + a single media fetch.
 */
const PLACE_DETAILS_FIELD_MASK =
  "id,displayName,formattedAddress,location,types,priceLevel,rating,userRatingCount,regularOpeningHours";

const TEXT_SEARCH_FIELD_MASK =
  "places.id,places.displayName,places.formattedAddress,places.location,places.types";

/** Day-plan Text Search: same minimal discovery fields as generic text search (no Place Details enrich). */
const TEXT_SEARCH_DAY_PLAN_FIELD_MASK = TEXT_SEARCH_FIELD_MASK;

async function cryptoHash(input: string): Promise<string> {
  const data = new TextEncoder().encode(input);
  const buf = await crypto.subtle.digest("SHA-256", data);
  const arr = Array.from(new Uint8Array(buf));
  return arr.map((b) => b.toString(16).padStart(2, "0")).join("");
}

// ── Adapters: New Places API v1 → legacy field shape ────────────────────

function priceLevelToNumber(s: string | undefined): number | undefined {
  const map: Record<string, number> = {
    PRICE_LEVEL_FREE: 0,
    PRICE_LEVEL_INEXPENSIVE: 1,
    PRICE_LEVEL_MODERATE: 2,
    PRICE_LEVEL_EXPENSIVE: 3,
    PRICE_LEVEL_VERY_EXPENSIVE: 4,
  };
  return s != null ? map[s] : undefined;
}

/**
 * Maps a Places API v1 place object to the legacy field shape that
 * placesNormalize.ts and writeBackPlaceCache() expect. This keeps all
 * consumers unchanged after the API migration.
 */
function adaptNewPlaceToOldShape(p: Record<string, unknown>): Record<string, unknown> {
  const displayName = p.displayName as Record<string, unknown> | undefined;
  const loc = p.location as Record<string, number> | undefined;
  const oh = p.regularOpeningHours as Record<string, unknown> | undefined;
  const rawReviews = Array.isArray(p.reviews) ? p.reviews : [];

  const reviews = rawReviews.map((rv: unknown) => {
    const r = rv as Record<string, unknown>;
    const textObj = r.text as Record<string, unknown> | undefined;
    const attr = r.authorAttribution as Record<string, unknown> | undefined;
    return {
      author_name: attr?.displayName ?? "Anonymous",
      rating: r.rating,
      text: textObj?.text ?? "",
      relative_time_description: r.relativePublishTimeDescription ?? null,
    };
  });

  return {
    place_id: p.id,
    name: displayName?.text ?? "",
    formatted_address: p.formattedAddress ?? "",
    geometry: {
      location: {
        lat: loc?.latitude,
        lng: loc?.longitude,
      },
    },
    types: p.types ?? [],
    rating: p.rating,
    user_ratings_total: p.userRatingCount,
    price_level: priceLevelToNumber(p.priceLevel as string | undefined),
    website: p.websiteUri ?? null,
    formatted_phone_number: p.nationalPhoneNumber ?? null,
    international_phone_number: p.internationalPhoneNumber ?? null,
    opening_hours: oh
      ? {
          open_now: oh.openNow ?? null,
          weekday_text: oh.weekdayDescriptions ?? [],
        }
      : undefined,
    reviews,
  };
}

// ── Place Details ───────────────────────────────────────────────────────

type SupabaseAdmin = ReturnType<typeof createClient>;

export type CachedPlaceDetailsOptions = {
  /**
   * When true, never calls OpenAI for AI copy — `ai_editorial_summary` and related fields
   * come only from Postgres (`city_places` via {@link augmentDetailsWithCityPlacePhotos} and
   * `place_cache` columns). User-facing `places-cache` `details` / `batch_details` use this.
   */
  skipAiEnrich?: boolean;
  /**
   * When set, skips Redis and Postgres read-through so Place Details (New) is called on Google
   * with this `sessionToken` query param. Required to close an Autocomplete (New) billing session;
   * cached rows would skip Google and leave the session “abandoned”.
   */
  autocompleteSessionToken?: string;
};

function mergeAiContent(
  data: Record<string, unknown>,
  ai: PlaceAiContent
): Record<string, unknown> {
  return {
    ...data,
    ai_editorial_summary: ai.editorialSummary,
    ai_review_summary: ai.quickTake,
    ai_why_go: ai.whyGo,
    ai_know_before_you_go: ai.knowBeforeYouGo,
  };
}

function placePatchNonEmptyString(
  patch: Record<string, unknown>,
  key: string,
  v: unknown,
): void {
  if (typeof v !== "string") return;
  const t = v.trim();
  if (t.length > 0) patch[key] = t;
}

function placePatchStringArray(patch: Record<string, unknown>, key: string, v: unknown): void {
  if (!Array.isArray(v) || v.length === 0) return;
  const out = v
    .filter((x): x is string => typeof x === "string" && x.trim().length > 0)
    .map((x) => x.trim());
  if (out.length > 0) patch[key] = out;
}

type CityPlaceDetailsAugmentRow = {
  name?: string | null;
  rating?: number | null;
  user_ratings_total?: number | null;
  price_level?: number | null;
  formatted_address?: string | null;
  subtypes?: string[] | null;
  reviews_tags?: string[] | null;
  ai_editorial_summary?: string | null;
  ai_review_summary?: string | null;
  ai_why_go?: unknown;
  ai_know_before_you_go?: unknown;
  ai_short_summary?: string | null;
  opening_hours?: unknown;
  popular_times?: unknown;
  images?: unknown;
  website?: string | null;
  formatted_phone_number?: string | null;
  international_phone_number?: string | null;
};

/** Merge curated `city_places` fields onto place details (sheet + client normalize). */
async function augmentDetailsWithCityPlacePhotos(
  admin: SupabaseAdmin | undefined,
  placeId: string,
  data: Record<string, unknown> | null,
): Promise<Record<string, unknown> | null> {
  if (!admin || !data) return data;
  try {
    const { data: rows, error } = await admin
      .from("city_places")
      .select(
        "name,rating,user_ratings_total,price_level,formatted_address,subtypes,reviews_tags,ai_editorial_summary,ai_review_summary,ai_why_go,ai_know_before_you_go,ai_short_summary,opening_hours,popular_times,images,website,formatted_phone_number,international_phone_number,last_refreshed_at",
      )
      .eq("place_id", placeId.trim())
      .order("last_refreshed_at", { ascending: false })
      .limit(24);
    if (error || !rows?.length) return data;

    const primary = rows[0] as CityPlaceDetailsAugmentRow;
    const patch: Record<string, unknown> = {};

    placePatchNonEmptyString(patch, "name", primary.name);
    placePatchNonEmptyString(patch, "formatted_address", primary.formatted_address);
    placePatchNonEmptyString(patch, "website", primary.website);
    placePatchNonEmptyString(patch, "formatted_phone_number", primary.formatted_phone_number);
    placePatchNonEmptyString(patch, "international_phone_number", primary.international_phone_number);

    if (typeof primary.rating === "number" && Number.isFinite(primary.rating)) {
      patch.rating = primary.rating;
    }
    if (typeof primary.user_ratings_total === "number" && Number.isFinite(primary.user_ratings_total)) {
      patch.user_ratings_total = primary.user_ratings_total;
    }
    if (typeof primary.price_level === "number" && Number.isFinite(primary.price_level)) {
      patch.price_level = primary.price_level;
    }

    placePatchNonEmptyString(patch, "ai_editorial_summary", primary.ai_editorial_summary);
    placePatchNonEmptyString(patch, "ai_review_summary", primary.ai_review_summary);
    placePatchNonEmptyString(patch, "ai_short_summary", primary.ai_short_summary);
    placePatchStringArray(patch, "ai_why_go", primary.ai_why_go);
    placePatchStringArray(patch, "ai_know_before_you_go", primary.ai_know_before_you_go);

    const oh = cityPoolOpeningHoursToGoogleOpeningHours(primary.opening_hours);
    if (oh) patch.opening_hours = oh;

    if (primary.popular_times != null && typeof primary.popular_times === "object") {
      patch.wayfind_city_place_popular_times = primary.popular_times;
    }

    placePatchStringArray(patch, "wayfind_city_place_subtypes", primary.subtypes);
    placePatchStringArray(patch, "wayfind_city_place_reviews_tags", primary.reviews_tags);

    const urls: string[] = [];
    for (const row of rows) {
      const r = row as CityPlaceDetailsAugmentRow;
      for (const u of collectHttpsPhotoUrlsFromCityPlaceImages(r.images)) {
        if (!urls.includes(u)) urls.push(u);
      }
    }
    if (urls.length > 0) patch.wayfind_city_place_photo_urls = urls;

    if (Object.keys(patch).length === 0) return data;
    return { ...data, ...patch };
  } catch {
    return data;
  }
}

export async function cachedPlaceDetails(
  placeId: string,
  admin?: SupabaseAdmin,
  options?: CachedPlaceDetailsOptions,
): Promise<{ data: Record<string, unknown> | null; fromCache: boolean }> {
  if (!GOOGLE_MAPS_API_KEY || !placeId.trim()) {
    return { data: null, fromCache: false };
  }
  const skipAiEnrich = options?.skipAiEnrich === true;
  const sessionClose = options?.autocompleteSessionToken?.trim();
  /** Must hit Google so the session token is consumed for Autocomplete session billing. */
  const forceGoogleForSession = Boolean(sessionClose);
  const key = `place_details:${placeId.trim()}`;

  // L1: Redis
  const cached = forceGoogleForSession ? null : await redisGet(key);
  if (cached) {
    try {
      const data = JSON.parse(cached) as Record<string, unknown>;
      if (!skipAiEnrich && !data.ai_editorial_summary) {
        // Await so the client receives AI fields on this response
        const aiContent = await enrichPlaceWithAI(data).catch((e) => {
          console.error("[cached_google] AI enrichment (L1 miss) failed", e);
          return null;
        });
        if (aiContent) {
          const enriched = mergeAiContent(data, aiContent);
          const withPhotos = await augmentDetailsWithCityPlacePhotos(admin, placeId, enriched);
          redisSet(key, JSON.stringify(withPhotos), TTL_PLACE_DETAILS_SECONDS);
          return { data: withPhotos, fromCache: true };
        }
      }
      const withPhotosL1 = await augmentDetailsWithCityPlacePhotos(admin, placeId, data);
      if (JSON.stringify(data) !== JSON.stringify(withPhotosL1)) {
        redisSet(key, JSON.stringify(withPhotosL1), TTL_PLACE_DETAILS_SECONDS);
      }
      return { data: withPhotosL1, fromCache: true };
    } catch { /* corrupted entry, refetch */ }
  }

  // L2: Postgres place_cache
  if (admin && !forceGoogleForSession) {
    try {
      const { data: row } = await admin
        .from("place_cache")
        .select(
          "details_json,ai_editorial_summary,ai_review_summary,ai_why_go,ai_know_before_you_go"
        )
        .eq("place_id", placeId.trim())
        .maybeSingle();
      if (row?.details_json && typeof row.details_json === "object") {
        const details = row.details_json as Record<string, unknown>;
        if (Object.keys(details).length > 3) {
          let aiFields = {
            ai_editorial_summary: row.ai_editorial_summary ?? null,
            ai_review_summary: row.ai_review_summary ?? null,
            ai_why_go: row.ai_why_go ?? null,
            ai_know_before_you_go: row.ai_know_before_you_go ?? null,
          };
          if (!skipAiEnrich && !row.ai_editorial_summary) {
            // Await so the client receives AI fields on this response
            const aiContent = await enrichPlaceWithAI(details).catch((e) => {
              console.error("[cached_google] AI enrichment (L2 miss) failed", e);
              return null;
            });
            if (aiContent) {
              aiFields = {
                ai_editorial_summary: aiContent.editorialSummary,
                ai_review_summary: aiContent.quickTake,
                ai_why_go: aiContent.whyGo,
                ai_know_before_you_go: aiContent.knowBeforeYouGo,
              };
            }
          }
          const withTs = { ...details, ...aiFields, _cached_at: new Date().toISOString() };
          const withPhotosL2 = await augmentDetailsWithCityPlacePhotos(admin, placeId, withTs);
          redisSet(key, JSON.stringify(withPhotosL2), TTL_PLACE_DETAILS_SECONDS);
          return { data: withPhotosL2, fromCache: true };
        }
      }
    } catch { /* postgres lookup failed, continue to Google */ }
  }

  // L3: Places API v1
  const result = await googlePlaceDetails(placeId.trim(), sessionClose);
  if (!result) return { data: null, fromCache: false };

  writeBackPlaceCache(admin, placeId.trim(), result);
  if (skipAiEnrich) {
    const withPhotosL3a = await augmentDetailsWithCityPlacePhotos(admin, placeId, result);
    redisSet(key, JSON.stringify(withPhotosL3a), TTL_PLACE_DETAILS_SECONDS);
    return { data: withPhotosL3a, fromCache: false };
  }
  // Await enrichment so the client receives AI fields on this first fetch
  const aiContent = await enrichPlaceWithAI(result).catch((e) => {
    console.error("[cached_google] AI enrichment (L3) failed", e);
    return null;
  });
  const enrichedResult = aiContent ? mergeAiContent(result, aiContent) : result;
  const withPhotosL3 = await augmentDetailsWithCityPlacePhotos(admin, placeId, enrichedResult);
  redisSet(key, JSON.stringify(withPhotosL3), TTL_PLACE_DETAILS_SECONDS);
  return { data: withPhotosL3, fromCache: false };
}

async function googlePlaceDetails(
  placeId: string,
  sessionToken?: string,
): Promise<Record<string, unknown> | null> {
  try {
    const st = sessionToken?.trim();
    const qs = st
      ? `?sessionToken=${encodeURIComponent(st)}`
      : "";
    const url = `${NEW_PLACES_BASE}/places/${encodeURIComponent(placeId)}${qs}`;
    const res = await fetch(url, {
      headers: {
        "X-Goog-Api-Key": GOOGLE_MAPS_API_KEY,
        "X-Goog-FieldMask": PLACE_DETAILS_FIELD_MASK,
      },
    });
    if (!res.ok) return null;
    const data = await res.json() as Record<string, unknown>;
    if (!data.id) return null;
    return adaptNewPlaceToOldShape(data);
  } catch {
    return null;
  }
}

function writeBackPlaceCache(
  admin: SupabaseAdmin | undefined,
  placeId: string,
  details: Record<string, unknown>,
): void {
  if (!admin) return;
  const geo = details.geometry as Record<string, unknown> | undefined;
  const loc = geo?.location as Record<string, number> | undefined;
  const types = details.types as string[] | undefined;

  admin
    .from("place_cache")
    .upsert(
      {
        place_id: placeId,
        name: (details.name as string)?.slice(0, 500) ?? null,
        address: (details.formatted_address as string) ?? null,
        latitude: loc?.lat ?? null,
        longitude: loc?.lng ?? null,
        rating: details.rating ?? null,
        price_level: details.price_level ?? null,
        types: types ?? [],
        details_json: details,
        fetched_at: new Date().toISOString(),
      },
      { onConflict: "place_id" },
    )
    .then(() => {})
    .catch((e: unknown) =>
      console.error("[cached_google] place_cache upsert failed:", e),
    );
}

// ── Batch Place Details ─────────────────────────────────────────────────

const BATCH_GOOGLE_CONCURRENCY = 5;

export async function cachedBatchPlaceDetails(
  placeIds: string[],
  admin?: SupabaseAdmin,
  options?: CachedPlaceDetailsOptions,
): Promise<Record<string, { data: Record<string, unknown> | null; fromCache: boolean }>> {
  const ids = placeIds.map((id) => id.trim()).filter((id) => id.length > 0);
  const results: Record<string, { data: Record<string, unknown> | null; fromCache: boolean }> = {};
  if (ids.length === 0) return results;

  const keys = ids.map((id) => `place_details:${id}`);
  const cached = await redisPipelineGet(keys);

  const misses: string[] = [];
  for (let i = 0; i < ids.length; i++) {
    if (cached[i]) {
      try {
        results[ids[i]] = { data: JSON.parse(cached[i]!), fromCache: true };
        continue;
      } catch { /* corrupted, refetch */ }
    }
    misses.push(ids[i]);
  }

  for (let i = 0; i < misses.length; i += BATCH_GOOGLE_CONCURRENCY) {
    const chunk = misses.slice(i, i + BATCH_GOOGLE_CONCURRENCY);
    await Promise.all(
      chunk.map(async (id) => {
        const { data, fromCache } = await cachedPlaceDetails(id, admin, options);
        results[id] = { data, fromCache };
      }),
    );
  }

  return results;
}

// ── Text Search ─────────────────────────────────────────────────────────

export type TextSearchResult = {
  place_id: string;
  name: string;
  formatted_address?: string;
  geometry?: { location: { lat: number; lng: number } };
  rating?: number;
  user_ratings_total?: number;
  price_level?: number;
  opening_hours?: { open_now?: boolean };
  types?: string[];
};

export async function cachedTextSearch(
  query: string,
  location?: { lat: number; lng: number },
  radius?: number,
  type?: string,
): Promise<{ results: TextSearchResult[]; fromCache: boolean }> {
  if (!GOOGLE_MAPS_API_KEY || !query.trim()) {
    return { results: [], fromCache: false };
  }

  const hasLocation = location != null;

  // Only cache when location is explicit (deterministic results)
  if (hasLocation) {
    const keyParts = `${query}|${location!.lat},${location!.lng}|${radius ?? ""}|${type ?? ""}`;
    const hash = await cryptoHash(keyParts);
    const cacheKey = `text_search:${hash}`;

    const cached = await redisGet(cacheKey);
    if (cached) {
      try {
        const parsed = JSON.parse(cached) as TextSearchResult[];
        return { results: parsed, fromCache: true };
      } catch { /* corrupted, refetch */ }
    }

    const results = await googleTextSearch(query, location, radius, type);
    if (results.length > 0) {
      redisSet(cacheKey, JSON.stringify(results), TTL_TEXT_SEARCH_SECONDS);
    }
    return { results, fromCache: false };
  }

  // No location — skip cache, call Google directly
  const results = await googleTextSearch(query, location, radius, type);
  return { results, fromCache: false };
}

// ── Text search (day planner — richer fields, separate cache key) ─────────

export type DayPlanTextSearchHit = {
  place_id: string;
  name: string;
  formatted_address: string;
  lat: number;
  lng: number;
  types: string[];
  rating: number | null;
  user_ratings_total: number | null;
  price_level: number | null;
  open_now: boolean | null;
};

function adaptNewPlaceToDayPlanHit(
  p: Record<string, unknown>,
): DayPlanTextSearchHit | null {
  const row = adaptNewPlaceToOldShape(p);
  const geo = row.geometry as Record<string, unknown> | undefined;
  const loc = geo?.location as Record<string, number> | undefined;
  const lat = loc?.lat;
  const lng = loc?.lng;
  if (typeof lat !== "number" || typeof lng !== "number" || !Number.isFinite(lat) || !Number.isFinite(lng)) {
    return null;
  }
  const pid = String(row.place_id ?? "").trim();
  if (!pid) return null;
  const name = String(row.name ?? "").trim();
  if (!name) return null;
  const types = Array.isArray(row.types) ? row.types as string[] : [];
  const oh = row.opening_hours as Record<string, unknown> | undefined;
  const openNow = typeof oh?.open_now === "boolean" ? oh.open_now : null;
  const rating = typeof row.rating === "number" && Number.isFinite(row.rating) ? row.rating : null;
  const urt = typeof row.user_ratings_total === "number" && Number.isFinite(row.user_ratings_total)
    ? row.user_ratings_total
    : null;
  const pl = typeof row.price_level === "number" && Number.isFinite(row.price_level) ? row.price_level : null;
  return {
    place_id: pid,
    name,
    formatted_address: String(row.formatted_address ?? ""),
    lat,
    lng,
    types,
    rating,
    user_ratings_total: urt,
    price_level: pl,
    open_now: openNow,
  };
}

async function googleTextSearchDayPlan(
  textQuery: string,
  location: { lat: number; lng: number },
  radiusMeters: number,
  includedType?: string,
): Promise<DayPlanTextSearchHit[]> {
  try {
    const requestBody: Record<string, unknown> = {
      textQuery: textQuery.trim(),
      maxResultCount: 20,
    };
    if (includedType) requestBody.includedType = includedType;
    requestBody.locationBias = {
      circle: {
        center: { latitude: location.lat, longitude: location.lng },
        radius: radiusMeters,
      },
    };

    const res = await fetch(`${NEW_PLACES_BASE}/places:searchText`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Goog-Api-Key": GOOGLE_MAPS_API_KEY,
        "X-Goog-FieldMask": TEXT_SEARCH_DAY_PLAN_FIELD_MASK,
      },
      body: JSON.stringify(requestBody),
    });

    if (!res.ok) return [];
    const data = await res.json() as Record<string, unknown>;
    const places = Array.isArray(data.places) ? data.places : [];
    const out: DayPlanTextSearchHit[] = [];
    for (const raw of places) {
      const hit = adaptNewPlaceToDayPlanHit(raw as Record<string, unknown>);
      if (hit) out.push(hit);
    }
    return out;
  } catch {
    return [];
  }
}

/**
 * Cached Places Text Search for day-plan discovery (light field mask).
 * Uses Redis namespace `text_search_dayplan:` (distinct from generic text search cache).
 */
export async function cachedTextSearchDayPlan(
  textQuery: string,
  location: { lat: number; lng: number },
  radiusMeters: number,
  includedType?: string,
): Promise<{ hits: DayPlanTextSearchHit[]; fromCache: boolean }> {
  if (!GOOGLE_MAPS_API_KEY || !textQuery.trim()) {
    return { hits: [], fromCache: false };
  }

  const keyParts =
    `dayplan|${textQuery}|${location.lat},${location.lng}|${radiusMeters}|${includedType ?? ""}`;
  const hash = await cryptoHash(keyParts);
  const cacheKey = `text_search_dayplan:${hash}`;

  const cached = await redisGet(cacheKey);
  if (cached) {
    try {
      const parsed = JSON.parse(cached) as DayPlanTextSearchHit[];
      return { hits: parsed, fromCache: true };
    } catch { /* refetch */ }
  }

  const hits = await googleTextSearchDayPlan(textQuery, location, radiusMeters, includedType);
  if (hits.length > 0) {
    redisSet(cacheKey, JSON.stringify(hits), TTL_TEXT_SEARCH_DAY_PLAN_SECONDS);
  }
  return { hits, fromCache: false };
}

async function googleTextSearch(
  query: string,
  location?: { lat: number; lng: number },
  radius?: number,
  type?: string,
): Promise<TextSearchResult[]> {
  try {
    const requestBody: Record<string, unknown> = { textQuery: query.trim() };
    if (type) requestBody.includedType = type;
    if (location) {
      requestBody.locationBias = {
        circle: {
          center: { latitude: location.lat, longitude: location.lng },
          radius: radius ?? 50000,
        },
      };
    }

    const res = await fetch(`${NEW_PLACES_BASE}/places:searchText`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Goog-Api-Key": GOOGLE_MAPS_API_KEY,
        "X-Goog-FieldMask": TEXT_SEARCH_FIELD_MASK,
      },
      body: JSON.stringify(requestBody),
    });

    if (!res.ok) return [];
    const data = await res.json() as Record<string, unknown>;
    const places = Array.isArray(data.places) ? data.places : [];
    return places.map((p: unknown) =>
      adaptNewPlaceToOldShape(p as Record<string, unknown>)
    ) as TextSearchResult[];
  } catch {
    return [];
  }
}

// ── Distance Matrix (compat) / Routes ───────────────────────────────────

const VALID_TRAVEL_MODES = new Set(["driving", "walking", "transit", "bicycling"]);

function normalizeTravelModeForRoutes(mode: string | undefined): string {
  return VALID_TRAVEL_MODES.has(mode ?? "") ? (mode as string) : "driving";
}

/** Protobuf JSON: duration field like "3600s" or "3600.5s". */
function parseRoutesDurationSeconds(raw: unknown): number | null {
  if (raw == null) return null;
  if (typeof raw === "number" && Number.isFinite(raw)) return raw;
  if (typeof raw !== "string") return null;
  const m = /^(\d+(?:\.\d+)?)s$/.exec(raw.trim());
  if (!m) return null;
  const sec = parseFloat(m[1]!);
  return Number.isFinite(sec) ? sec : null;
}

type CachedRouteLegV1 = {
  v: 1;
  encodedPolyline: string;
  durationSeconds: number;
  distanceMeters: number | null;
};

function parseDirectionsRedisValue(cached: string): {
  encodedPolyline: string | null;
  durationSeconds: number | null;
  distanceMeters: number | null;
  needsRefresh: boolean;
} {
  const empty = (): {
    encodedPolyline: null;
    durationSeconds: null;
    distanceMeters: null;
    needsRefresh: true;
  } => ({
    encodedPolyline: null,
    durationSeconds: null,
    distanceMeters: null,
    needsRefresh: true,
  });

  if (!cached.length) return empty();

  try {
    const o = JSON.parse(cached) as unknown;
    if (o && typeof o === "object" && !Array.isArray(o)) {
      const rec = o as Record<string, unknown>;
      if (rec.v === 1 && typeof rec.encodedPolyline === "string") {
        const leg = rec as unknown as CachedRouteLegV1;
        const dur =
          typeof leg.durationSeconds === "number" && Number.isFinite(leg.durationSeconds)
            ? leg.durationSeconds
            : null;
        const dm =
          leg.distanceMeters != null &&
          typeof leg.distanceMeters === "number" &&
          Number.isFinite(leg.distanceMeters)
            ? leg.distanceMeters
            : null;
        if (dur != null && leg.encodedPolyline.length > 0) {
          return {
            encodedPolyline: leg.encodedPolyline,
            durationSeconds: dur,
            distanceMeters: dm,
            needsRefresh: false,
          };
        }
      }
    }
    // JSON but not a valid v1 payload — do not treat as polyline.
    return empty();
  } catch {
    /* legacy: raw encoded polyline string */
  }

  return {
    encodedPolyline: cached,
    durationSeconds: null,
    distanceMeters: null,
    needsRefresh: true,
  };
}

const ROUTES_COMPUTE_FIELD_MASK =
  "routes.duration,routes.distanceMeters,routes.polyline.encodedPolyline";

export type CachedDirectionsResult = {
  encodedPolyline: string | null;
  durationSeconds: number | null;
  distanceMeters: number | null;
  fromCache: boolean;
};

/**
 * Routes API `computeRoutes` — polyline + duration + distance in one request/cached blob.
 * Legacy Redis values (polyline string only) are refreshed on read to attach duration.
 */
export async function cachedDirections(
  origin: { lat: number; lng: number },
  dest: { lat: number; lng: number },
  mode = "driving",
): Promise<CachedDirectionsResult> {
  if (!GOOGLE_MAPS_API_KEY) {
    return {
      encodedPolyline: null,
      durationSeconds: null,
      distanceMeters: null,
      fromCache: false,
    };
  }

  const m = normalizeTravelModeForRoutes(mode);
  const travelModeMap: Record<string, string> = {
    driving: "DRIVE",
    walking: "WALK",
    bicycling: "BICYCLE",
    transit: "TRANSIT",
  };

  const keyParts = `${origin.lat},${origin.lng}|${dest.lat},${dest.lng}|${m}`;
  const hash = await cryptoHash(keyParts);
  const cacheKey = `directions:${hash}`;

  let stalePolylineOnly: string | null = null;
  const cached = await redisGet(cacheKey);
  if (cached) {
    const parsed = parseDirectionsRedisValue(cached);
    if (!parsed.needsRefresh && parsed.encodedPolyline && parsed.durationSeconds != null) {
      return {
        encodedPolyline: parsed.encodedPolyline,
        durationSeconds: parsed.durationSeconds,
        distanceMeters: parsed.distanceMeters,
        fromCache: true,
      };
    }
    if (parsed.needsRefresh && parsed.encodedPolyline) {
      stalePolylineOnly = parsed.encodedPolyline;
    }
  }

  const staleFallback = (poly: string): CachedDirectionsResult => ({
    encodedPolyline: poly,
    durationSeconds: null,
    distanceMeters: null,
    fromCache: true,
  });

  const empty = (): CachedDirectionsResult => ({
    encodedPolyline: null,
    durationSeconds: null,
    distanceMeters: null,
    fromCache: false,
  });

  try {
    const res = await fetch(
      "https://routes.googleapis.com/directions/v2:computeRoutes",
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Goog-Api-Key": GOOGLE_MAPS_API_KEY,
          "X-Goog-FieldMask": ROUTES_COMPUTE_FIELD_MASK,
        },
        body: JSON.stringify({
          origin: {
            location: { latLng: { latitude: origin.lat, longitude: origin.lng } },
          },
          destination: {
            location: { latLng: { latitude: dest.lat, longitude: dest.lng } },
          },
          travelMode: travelModeMap[m] ?? "DRIVE",
        }),
      },
    );

    if (!res.ok) {
      return stalePolylineOnly ? staleFallback(stalePolylineOnly) : empty();
    }
    const data = (await res.json()) as Record<string, unknown>;
    if (data.error) {
      return stalePolylineOnly ? staleFallback(stalePolylineOnly) : empty();
    }

    const routes = data.routes as
      | Array<{
        duration?: unknown;
        distanceMeters?: unknown;
        polyline?: { encodedPolyline?: string };
      }>
      | undefined;
    const route0 = routes?.[0];
    const encoded = route0?.polyline?.encodedPolyline;
    const durationSeconds = parseRoutesDurationSeconds(route0?.duration);
    const distanceMeters =
      route0?.distanceMeters != null && typeof route0.distanceMeters === "number" &&
        Number.isFinite(route0.distanceMeters)
        ? route0.distanceMeters
        : null;

    if (!encoded || encoded.length === 0 || durationSeconds == null) {
      if (typeof encoded === "string" && encoded.length > 0) {
        return {
          encodedPolyline: encoded,
          durationSeconds: null,
          distanceMeters,
          fromCache: false,
        };
      }
      return stalePolylineOnly ? staleFallback(stalePolylineOnly) : empty();
    }

    const payload: CachedRouteLegV1 = {
      v: 1,
      encodedPolyline: encoded,
      durationSeconds,
      distanceMeters,
    };
    redisSet(cacheKey, JSON.stringify(payload), TTL_ROUTES_DIRECTIONS_SECONDS);

    return {
      encodedPolyline: encoded,
      durationSeconds,
      distanceMeters,
      fromCache: false,
    };
  } catch {
    return stalePolylineOnly ? staleFallback(stalePolylineOnly) : empty();
  }
}

/** Back-compat for `places-cache` action `distance_matrix` — uses Routes API via `cachedDirections`. */
export async function cachedDistanceMatrix(
  from: { lat: number; lng: number },
  to: { lat: number; lng: number },
  mode = "driving",
): Promise<{ minutes: number | null; fromCache: boolean }> {
  const { durationSeconds, fromCache } = await cachedDirections(from, to, mode);
  if (durationSeconds == null) return { minutes: null, fromCache };
  return { minutes: Math.round(durationSeconds / 60), fromCache };
}

// ── Timezone ────────────────────────────────────────────────────────────

export async function cachedTimezone(
  lat: number,
  lng: number,
): Promise<{ timeZoneId: string | null; fromCache: boolean }> {
  if (!GOOGLE_MAPS_API_KEY) return { timeZoneId: null, fromCache: false };

  const latR = lat.toFixed(3);
  const lngR = lng.toFixed(3);
  const cacheKey = `timezone:${latR}_${lngR}`;

  const cached = await redisGet(cacheKey);
  if (cached) return { timeZoneId: cached, fromCache: true };

  const ts = Math.floor(Date.now() / 1000);
  const apiUrl = new URL("https://maps.googleapis.com/maps/api/timezone/json");
  apiUrl.searchParams.set("location", `${lat},${lng}`);
  apiUrl.searchParams.set("timestamp", String(ts));
  apiUrl.searchParams.set("key", GOOGLE_MAPS_API_KEY);

  try {
    const res = await fetch(apiUrl.toString());
    if (!res.ok) return { timeZoneId: null, fromCache: false };
    const data = await res.json();
    if (data.status !== "OK" || typeof data.timeZoneId !== "string") {
      return { timeZoneId: null, fromCache: false };
    }
    // Cache only the IANA timeZoneId (DST-invariant), not offsets
    redisSet(cacheKey, data.timeZoneId, TTL_TIMEZONE_SECONDS);
    return { timeZoneId: data.timeZoneId, fromCache: false };
  } catch {
    return { timeZoneId: null, fromCache: false };
  }
}

// ── Geocoding ───────────────────────────────────────────────────────────

export async function cachedGeocode(
  address: string,
): Promise<{ result: Record<string, unknown> | null; fromCache: boolean }> {
  if (!GOOGLE_MAPS_API_KEY || !address.trim()) {
    return { result: null, fromCache: false };
  }

  const hash = await cryptoHash(address.trim().toLowerCase());
  const cacheKey = `geocode:${hash}`;

  const cached = await redisGet(cacheKey);
  if (cached) {
    try {
      return { result: JSON.parse(cached), fromCache: true };
    } catch { /* corrupted */ }
  }

  try {
    const u = new URL("https://maps.googleapis.com/maps/api/geocode/json");
    u.searchParams.set("address", address.trim());
    u.searchParams.set("key", GOOGLE_MAPS_API_KEY);

    const res = await fetch(u.toString());
    if (!res.ok) return { result: null, fromCache: false };
    const data = await res.json();
    if (data.status !== "OK" || !data.results?.length) {
      return { result: null, fromCache: false };
    }
    const first = data.results[0] as Record<string, unknown>;
    redisSet(cacheKey, JSON.stringify(first), TTL_GEOCODE_SECONDS);
    return { result: first, fromCache: false };
  } catch {
    return { result: null, fromCache: false };
  }
}



