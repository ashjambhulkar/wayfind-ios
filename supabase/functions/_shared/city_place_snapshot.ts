import type { CityPlaceSnapshot } from "../../../types/cityPlaceSnapshot.ts";

function trimStr(v: unknown, maxLen: number): string | null {
  if (typeof v !== "string") return null;
  const t = v.trim();
  if (t.length === 0) return null;
  return t.length > maxLen ? t.slice(0, maxLen) : t;
}

function optNum(v: unknown): number | null {
  if (typeof v !== "number" || !Number.isFinite(v)) return null;
  return v;
}

function optInt(v: unknown): number | null {
  const n = optNum(v);
  if (n == null) return null;
  return Math.round(n);
}

function optStr(v: unknown, max: number): string | null {
  return trimStr(v, max);
}

function optStringArray(v: unknown, maxItems: number, itemMax: number): string[] | null {
  if (!Array.isArray(v)) return null;
  const out: string[] = [];
  for (const x of v) {
    if (typeof x !== "string") continue;
    const s = x.trim().slice(0, itemMax);
    if (s.length > 0) out.push(s);
    if (out.length >= maxItems) break;
  }
  return out.length > 0 ? out : null;
}

/** Build a client-safe snapshot from a `city_places` row (`select('*')` shape). */
export function buildCityPlaceSnapshotFromDbRow(
  p: Record<string, unknown>,
): CityPlaceSnapshot | null {
  const place_id = typeof p.place_id === "string" ? p.place_id.trim() : "";
  const name = typeof p.name === "string" ? p.name.trim() : "";
  if (!place_id || !name) return null;
  const lat = typeof p.lat === "number" && Number.isFinite(p.lat) ? p.lat : NaN;
  const lng = typeof p.lng === "number" && Number.isFinite(p.lng) ? p.lng : NaN;
  if (!Number.isFinite(lat) || !Number.isFinite(lng)) return null;

  const snap: CityPlaceSnapshot = {
    id: optStr(p.id, 80),
    city_profile_id: optStr(p.city_profile_id, 80),
    place_id,
    name: name.slice(0, 500),
    lat,
    lng,
    formatted_address: optStr(p.formatted_address, 2000),
    types: optStringArray(p.types, 64, 200),
    wayfind_category: optStr(p.wayfind_category, 64),
    min_scope: optStr(p.min_scope, 32),
    tier: optInt(p.tier),
    source_query_count: optInt(p.source_query_count),
    dist_from_center_km: optNum(p.dist_from_center_km),
    source_query: optStr(p.source_query, 2000),
    status: optStr(p.status, 32),
    reported_count: optInt(p.reported_count),
    reported_at: optStr(p.reported_at, 64),
    last_refreshed_at: optStr(p.last_refreshed_at, 64),
    created_at: optStr(p.created_at, 64),
    rating: optNum(p.rating),
    user_ratings_total: optInt(p.user_ratings_total),
    price_level: optInt(p.price_level),
    opening_hours: p.opening_hours ?? null,
    details_enriched_at: optStr(p.details_enriched_at, 64),
    ai_short_summary: optStr(p.ai_short_summary, 500),
    ai_editorial_summary: optStr(p.ai_editorial_summary, 12000),
    ai_review_summary: optStr(p.ai_review_summary, 12000),
    ai_why_go: optStringArray(p.ai_why_go, 40, 500),
    ai_know_before_you_go: optStringArray(p.ai_know_before_you_go, 40, 500),
    ai_enriched_at: optStr(p.ai_enriched_at, 64),
    formatted_phone_number: optStr(p.formatted_phone_number, 120),
    international_phone_number: optStr(p.international_phone_number, 120),
    website: optStr(p.website, 2000),
    images: p.images ?? null,
    thumbnail_url: optStr(p.thumbnail_url, 2000),
    popular_times: p.popular_times ?? null,
    subtypes: optStringArray(p.subtypes, 64, 200),
    reviews_tags: optStringArray(p.reviews_tags, 64, 120),
    time_spent_min: optInt(p.time_spent_min),
    time_spent_max: optInt(p.time_spent_max),
    time_spent_enriched_at: optStr(p.time_spent_enriched_at, 64),
  };

  return snap;
}

const SNAPSHOT_STRING_KEYS = [
  "id",
  "city_profile_id",
  "place_id",
  "name",
  "formatted_address",
  "wayfind_category",
  "min_scope",
  "source_query",
  "status",
  "reported_at",
  "last_refreshed_at",
  "created_at",
  "details_enriched_at",
  "ai_short_summary",
  "ai_editorial_summary",
  "ai_review_summary",
  "ai_enriched_at",
  "formatted_phone_number",
  "international_phone_number",
  "website",
  "thumbnail_url",
  "time_spent_enriched_at",
] as const;

const SNAPSHOT_NUMBER_KEYS = [
  "tier",
  "source_query_count",
  "dist_from_center_km",
  "reported_count",
  "rating",
  "user_ratings_total",
  "price_level",
  "time_spent_min",
  "time_spent_max",
] as const;

/** Whitelist + trim strings for Edge → client `nearby_meals.city_place`. */
export function sanitizeCityPlaceSnapshotForClient(raw: unknown): CityPlaceSnapshot | undefined {
  if (!raw || typeof raw !== "object") return undefined;
  const o = raw as Record<string, unknown>;
  const place_id = typeof o.place_id === "string" ? o.place_id.trim().slice(0, 500) : "";
  const name = typeof o.name === "string" ? o.name.trim().slice(0, 500) : "";
  if (!place_id || !name) return undefined;

  const lat = typeof o.lat === "number" && Number.isFinite(o.lat) ? o.lat : null;
  const lng = typeof o.lng === "number" && Number.isFinite(o.lng) ? o.lng : null;
  if (lat == null || lng == null) return undefined;

  const out: Record<string, unknown> = { place_id, name, lat, lng };

  for (const k of SNAPSHOT_STRING_KEYS) {
    if (k === "place_id" || k === "name") continue;
    const v = o[k];
    if (typeof v !== "string") continue;
    const t = v.trim();
    if (t.length === 0) continue;
    out[k] = t.length > 12000 ? t.slice(0, 12000) : t;
  }

  for (const k of SNAPSHOT_NUMBER_KEYS) {
    const v = o[k];
    if (typeof v !== "number" || !Number.isFinite(v)) continue;
    out[k] = v;
  }

  for (const key of ["types", "ai_why_go", "ai_know_before_you_go", "subtypes", "reviews_tags"] as const) {
    const v = o[key];
    if (!Array.isArray(v)) continue;
    const arr: string[] = [];
    for (const x of v) {
      if (typeof x !== "string") continue;
      const s = x.trim().slice(0, 500);
      if (s.length > 0) arr.push(s);
      if (arr.length >= 64) break;
    }
    if (arr.length > 0) out[key] = arr;
  }

  const jsonCap = 24_000;
  for (const key of ["opening_hours", "images", "popular_times"] as const) {
    if (!(key in o)) continue;
    const v = o[key];
    try {
      const s = JSON.stringify(v);
      if (s.length <= jsonCap) out[key] = JSON.parse(s) as unknown;
    } catch {
      /* omit invalid / oversized JSON */
    }
  }

  return out as CityPlaceSnapshot;
}
