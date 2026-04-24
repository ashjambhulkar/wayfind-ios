/**
 * Change 7 Part 6: helpers for querying `city_places` in the itinerary candidate pipeline.
 */

import type { CandidatePlaceInput } from "./day_plan_candidate_rank_core.ts";

/** Rows eligible for itinerary pools (reported venues stay until 3+ reports remove them). */
export const CITY_PLACES_IN_POOL_STATUSES = ["active", "reported"] as const;

export type CityPlaceDbRow = {
  place_id: string;
  name: string;
  lat: number;
  lng: number;
  formatted_address: string | null;
  types: string[] | null;
  wayfind_category: string;
  min_scope: string;
  tier: number;
  source_query_count: number;
  /** Google `regularOpeningHours` JSON when enriched (Change 9). */
  opening_hours?: unknown | null;
  user_ratings_total?: number | null;
  rating?: number | null;
  price_level?: number | null;
  time_spent_min?: number | null;
  time_spent_max?: number | null;
  /** SerpApi enrichment fields */
  popular_times?: Record<string, { time: string; busyness_score: number }[]> | null;
  description?: string | null;
  subtypes?: string[] | null;
  reviews_tags?: string[] | null;
  website?: string | null;
  thumbnail_url?: string | null;
  /** Photo metadata JSON; first URL may be used when `thumbnail_url` is null. */
  images?: unknown | null;
};

const IMAGE_OBJECT_URL_KEYS = [
  "url",
  "thumbnail",
  "serpapi_thumbnail",
  "photo_uri",
  "photoUri",
  "link",
  "src",
] as const;

function trimUrl(v: unknown): string | null {
  if (typeof v !== "string") return null;
  const t = v.trim();
  return t.length > 0 ? t : null;
}

function firstUrlFromImageObject(o: Record<string, unknown>): string | null {
  for (const k of IMAGE_OBJECT_URL_KEYS) {
    const u = trimUrl(o[k]);
    if (u) return u;
  }
  return null;
}

/** Normalize JSONB / API quirks: double-encoded JSON string or a lone URL string. */
function normalizeImagesArrayInput(images: unknown): unknown {
  if (images == null) return null;
  if (typeof images === "string") {
    const t = images.trim();
    if (t.length === 0) return null;
    if (t.startsWith("[") || t.startsWith("{")) {
      try {
        return JSON.parse(t) as unknown;
      } catch {
        return null;
      }
    }
    if (/^https?:\/\//i.test(t)) return [t];
    return null;
  }
  return images;
}

/**
 * First usable image URL from `city_places.images` (array of strings or objects with url-like keys).
 */
export function firstImageUrlFromImagesJson(images: unknown): string | null {
  const parsed = normalizeImagesArrayInput(images);
  if (parsed == null) return null;
  if (!Array.isArray(parsed) || parsed.length === 0) return null;
  for (const item of parsed) {
    if (typeof item === "string") {
      const u = trimUrl(item);
      if (u) return u;
      continue;
    }
    if (item != null && typeof item === "object") {
      const u = firstUrlFromImageObject(item as Record<string, unknown>);
      if (u) return u;
    }
  }
  return null;
}

function isHttpsUrlString(s: string): boolean {
  return /^https?:\/\//i.test(s.trim());
}

/**
 * Ordered, deduped `https` URLs from `city_places.images` only (gallery — not `thumbnail_url`).
 * Used for `wayfind_city_place_photo_urls` on place-details payloads.
 */
export function collectHttpsPhotoUrlsFromCityPlaceImages(images: unknown): string[] {
  const out: string[] = [];
  const push = (raw: string | null | undefined) => {
    if (typeof raw !== "string") return;
    const u = raw.trim();
    if (!u || !isHttpsUrlString(u)) return;
    if (!out.includes(u)) out.push(u);
  };

  const parsed = normalizeImagesArrayInput(images);
  if (!Array.isArray(parsed)) return out;
  for (const item of parsed) {
    if (typeof item === "string") {
      push(item);
      continue;
    }
    if (item != null && typeof item === "object") {
      const uObj = firstUrlFromImageObject(item as Record<string, unknown>);
      if (uObj) push(uObj);
    }
  }
  return out;
}

/**
 * `city_places.opening_hours` JSON array `{ day, hours }[]` → legacy Google-style
 * `opening_hours` for {@link extractPlaceDetailsDisplay}-style clients.
 */
export function cityPoolOpeningHoursToGoogleOpeningHours(
  raw: unknown,
): { open_now: boolean | null; weekday_text: string[] } | undefined {
  if (!Array.isArray(raw) || raw.length === 0) return undefined;
  const weekday_text: string[] = [];
  for (const item of raw) {
    if (!item || typeof item !== "object") continue;
    const o = item as Record<string, unknown>;
    const day = typeof o.day === "string" ? o.day.trim() : "";
    const hours = typeof o.hours === "string" ? o.hours.trim() : "";
    if (!day || !hours) continue;
    const dayTitle = day.charAt(0).toUpperCase() + day.slice(1).toLowerCase();
    weekday_text.push(`${dayTitle}: ${hours}`);
  }
  if (weekday_text.length === 0) return undefined;
  return { open_now: null, weekday_text };
}

/** Prefer explicit `thumbnail_url`; if empty, first URL from `images`. */
export function effectiveThumbnailFromParts(
  thumbnailUrl: string | null | undefined,
  images: unknown,
): string | null {
  const direct = typeof thumbnailUrl === "string" ? thumbnailUrl.trim() : "";
  if (direct.length > 0) return direct;
  return firstImageUrlFromImagesJson(images);
}

/** Prefer `thumbnail_url`; if empty, first URL from `images`. */
export function effectiveCityPlaceThumbnailUrl(row: CityPlaceDbRow): string | null {
  return effectiveThumbnailFromParts(row.thumbnail_url, row.images);
}

export function scopeToMinScopeFilter(scope: string): string[] {
  switch (scope) {
    case "walkable":
      return ["walkable"];
    case "city_wide":
      return ["walkable", "city_wide"];
    case "spread_out":
      return ["walkable", "city_wide", "spread_out"];
    default:
      return ["walkable", "city_wide"];
  }
}

export function dbPlaceToCandidateInput(row: CityPlaceDbRow): CandidatePlaceInput {
  return {
    place_id: row.place_id,
    name: row.name,
    types: row.types ?? [],
    rating: row.rating ?? null,
    user_ratings_total: row.user_ratings_total ?? null,
    price_level: row.price_level ?? null,
    lat: row.lat,
    lng: row.lng,
    formatted_address: row.formatted_address ?? undefined,
    open_now: null,
    list_hit_count: Math.max(1, row.source_query_count ?? 1),
    thumbnail_url: effectiveCityPlaceThumbnailUrl(row),
  };
}



