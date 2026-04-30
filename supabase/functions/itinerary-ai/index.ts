import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { DateTime } from "https://esm.sh/luxon@3.4.4";
import {
  cachedDirections,
  cachedPlaceDetails,
  cachedTimezone,
} from "../_shared/cached_google.ts";
import {
  buildDefaultProfile,
  deriveCityLabel,
  getProfileDistCap,
  getProfileMaxRouteKm,
  getProfileRadius,
  matchCityProfile,
  type CityProfile,
} from "../_shared/city_profile_lookup.ts";
import {
  type ExplorationScope,
  fetchPlanDayCandidatePool,
} from "../_shared/day_plan_candidate_pipeline.ts";
import { computeRouteTotalKm } from "../_shared/itinerary_route_distance.ts";
import type { RankedCandidate } from "../_shared/day_plan_candidate_rank_core.ts";
import { sanitizeCityPlaceSnapshotForClient } from "../_shared/city_place_snapshot.ts";
import { firstImageUrlFromImagesJson, type CityPlaceDbRow } from "../_shared/city_places_pool.ts";
import {
  executePlanDayHybrid,
  type ActivityAlternative,
  type NearbyMealSuggestion,
} from "../_shared/plan_day_hybrid.ts";
import {
  type ItineraryAiAuditBase,
  jsonResponseWithAudit,
  logItineraryAiStart,
  logItineraryAiStep,
} from "../_shared/itinerary_ai_audit_log.ts";
import {
  captureException,
  errorMessage,
  initSentry,
  safeLog,
} from "../_shared/observability.ts";
import {
  ALLOWED_EXPLORATION_SCOPES,
  computeAdaptivePickRange,
  V2B_DEFAULT_EXPLORATION_SCOPE,
  V2B_MONTHLY_LIMIT_AI_DAY_PLANNER,
  WISHLIST_MIN_PICKS,
  WISHLIST_MIN_PICKS_FLOOR,
} from "../_shared/v2b_ai_constants.ts";
import { openaiItineraryModel } from "../_shared/openai_itinerary_models.ts";

const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY");
const FUNCTION_NAME = "itinerary-ai";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const GOOGLE_MAPS_API_KEY = Deno.env.get("GOOGLE_MAPS_API_KEY") ?? "";

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Content-Type": "application/json",
};

/**
 * V2b Stage 0 contract (request/response + apply_itinerary_ops payload):
 * ../../../.cursor/plans/V2b_Stage0_Contracts_and_Decisions.md
 *
 * Summary: Bearer JWT + trip_id; actions recompute_legs | compute_leg | resolve_timezone;
 * default path requires `message` (NL plan). Persists via RPC apply_itinerary_ops(
 *   { p_trip_id, p_actor_id, p_payload: { ops } }).
 * V2b structured plan_day — hybrid path only (see types/itineraryAiContracts.ts in app).
 */

const MAX_AI_DESCRIPTION_LEN = 400;
const MAX_MOMENT_LINE_LEN = 200;
const MAX_STORED_DESCRIPTION_LEN = 950;
const MAX_STORY_TITLE_LEN = 72;
const MAX_STORY_SUBTITLE_LEN = 140;
const MAX_STORY_ARC_LABEL_LEN = 40;
const MAX_STORY_ARC_COUNT = 5;

const ALLOWED_CATEGORIES = new Set([
  "attraction",
  "restaurant",
  "transport",
  "shopping",
  "nature",
  "nightlife",
  "custom",
]);

/** Map model / Google-style types to Wayfind `trip_activities.category` (avoids everything becoming `custom`). */
function normalizePlanCategory(raw: string | undefined | null): string {
  const s = String(raw ?? "").trim().toLowerCase().replace(/\s+/g, "_");
  if (ALLOWED_CATEGORIES.has(s)) return s;

  const synonyms: Record<string, string> = {
    museum: "attraction",
    art_gallery: "attraction",
    tourist_attraction: "attraction",
    library: "attraction",
    church: "attraction",
    hindu_temple: "attraction",
    mosque: "attraction",
    synagogue: "attraction",
    zoo: "attraction",
    aquarium: "attraction",
    amusement_park: "attraction",
    movie_theater: "attraction",
    spa: "attraction",
    casino: "nightlife",
    night_club: "nightlife",
    bakery: "restaurant",
    cafe: "restaurant",
    food: "restaurant",
    meal_delivery: "restaurant",
    meal_takeaway: "restaurant",
    bar: "nightlife",
    convenience_store: "shopping",
    supermarket: "shopping",
    shopping_mall: "shopping",
    clothing_store: "shopping",
    shoe_store: "shopping",
    department_store: "shopping",
    furniture_store: "shopping",
    hardware_store: "shopping",
    jewelry_store: "shopping",
    book_store: "shopping",
    florist: "shopping",
    park: "nature",
    campground: "nature",
    hiking_area: "nature",
    natural_feature: "nature",
    national_park: "nature",
    train_station: "transport",
    subway_station: "transport",
    bus_station: "transport",
    airport: "transport",
    taxi_stand: "transport",
    light_rail_station: "transport",
    transit_station: "transport",
    lodging: "attraction",
    hotel: "attraction",
  };

  const mapped = synonyms[s];
  if (mapped && ALLOWED_CATEGORIES.has(mapped)) return mapped;

  if (
    s.includes("museum") || s.includes("gallery") || s.includes("monument") ||
    s.includes("historic")
  ) {
    return "attraction";
  }
  if (
    s.includes("restaurant") || s.includes("dining") || s.includes("eatery") ||
    s.includes("food") || s.includes("cafe") || s.includes("coffee")
  ) {
    return "restaurant";
  }
  if (s.includes("park") || s.includes("garden") || s.includes("nature") || s.includes("forest")) {
    return "nature";
  }
  if (s.includes("shop") || s.includes("market") || s.includes("mall") || s.includes("store")) {
    return "shopping";
  }
  if (s.includes("club") || s.includes("pub") || s.includes("lounge")) {
    return "nightlife";
  }
  if (
    s.includes("station") || s.includes("airport") || s.includes("transit") ||
    s.includes("ferry")
  ) {
    return "transport";
  }

  return "custom";
}

type RequestBody = {
  trip_id?: string;
  date_from?: string;
  date_to?: string;
  /** `recompute_legs` | `compute_leg` | `resolve_timezone` | `plan_day` */
  action?: string;
  /** For compute_leg: origin activity. */
  from?: { lat: number; lng: number; name?: string };
  /** For compute_leg: destination activity. */
  to?: { lat: number; lng: number; name?: string; place_id?: string };
  /** For compute_leg: single travel mode to fetch distance for (others get directions_url only). */
  mode?: string;
  /** Structured single-day plan (V2b). */
  day_id?: string;
  destination?: string;
  date?: string;
  interests?: string[];
  pace?: string;
  stop_count_min?: number;
  stop_count_max?: number;
  time_start?: string;
  time_end?: string;
  include_meals?: boolean;
  exclude_places?: string[];
  /** Lodging / neighborhood anchor for candidate POI search. */
  stay_area_label?: string;
  stay_area_place_id?: string;
  /** Search radius + distance cap preset (Change 5). Default `city_wide` when omitted. */
  exploration_scope?: string;
  travel_style?: string;
  /** When true with `plan_day`, return `itinerary_ops` without applying (client applies via `apply_plan_day_ops`). */
  preview_only?: boolean;
  /** For `apply_plan_day_ops`: ops from a prior `plan_day` preview response. */
  itinerary_ops?: unknown[];
  /** For `report_place` (Change 7 Part 4): Google `place_id` + matching `city_profiles.id`. */
  place_id?: string;
  city_profile_id?: string;
  /** Optional short code from the client (`closed` | `wrong_location` | `other`). */
  reason?: string;
};

type DayRow = {
  id: string;
  date: string;
  label: string | null;
};

type ActivityRow = {
  id: string;
  day_id: string;
  source: string;
  name: string;
  description: string | null;
  starts_at: string | null;
  sort_order: number;
  latitude: number | null;
  longitude: number | null;
};

type ProposedActivity = {
  day_date: string;
  name: string;
  description: string;
  /** Model hint for time-of-day chapter (not persisted on trip_activities). */
  phase_label?: string | null;
  /** One short sentence: why this stop belongs in the day’s story (preview / emotional beat). Not a venue database entry. */
  moment_line?: string | null;
  category: string;
  /** Wall clock at destination (24h HH:mm). Preferred over naive starts_at. */
  local_time?: string | null;
  starts_at?: string | null;
  duration_minutes?: number | null;
  place_query?: string | null;
  /** When using ranked Google candidate pool, copy from candidate JSON (improves resolve + trust). */
  place_id?: string | null;
  estimated_cost?: number | null;
  currency?: string | null;
  rating?: number | null;
  price_level?: number | null;
  /** When true, this meal stop should not be reordered by route optimization (restaurant / cafe anchors). */
  meal_anchor?: boolean | null;
  /** From `city_places.thumbnail_url` (hybrid); persisted on insert as `hero_image_url`. */
  thumbnail_url?: string | null;
  /** From `city_places.images` (hybrid); preview UI prefers first URL over thumbnail. */
  images?: unknown | null;
  /** Hybrid / rich preview — forwarded on insert row for AI Day Planner UI only. */
  tips?: string[];
  alternatives?: ActivityAlternative[];
  nearby_meals?: NearbyMealSuggestion[];
};

type ParsedPlan = {
  summary: string;
  /** Optional editorial title for previews (≤ ~72 chars). Falls back to summary shaping on the client. */
  story_title?: string | null;
  /** Optional one-sentence arc for previews (≤ ~140 chars). */
  story_subtitle?: string | null;
  /** Short flow labels for UI (e.g. Culture, Lunch, Nature). */
  story_arc?: string[];
  replace_ai_days?: string[];
  activities: ProposedActivity[];
};

const PLAN_DAY_ACTION = "plan_day";
const APPLY_PLAN_DAY_OPS_ACTION = "apply_plan_day_ops";
/** Change 7 Part 4: user-reported closure / quality signal for `city_places`. */
const REPORT_PLACE_ACTION = "report_place";

const ALLOWED_PLAN_PACE = new Set(["relaxed", "balanced", "packed"]);
function normalizeExplorationScope(raw: unknown): ExplorationScope {
  const s = typeof raw === "string" ? raw.trim().toLowerCase() : "";
  if (ALLOWED_EXPLORATION_SCOPES.has(s)) {
    return s as ExplorationScope;
  }
  return V2B_DEFAULT_EXPLORATION_SCOPE as ExplorationScope;
}

/** Part 6: max total inter-stop distance (km) when no `city_profiles` row (matches plan defaults). */
const DEFAULT_MAX_ROUTE_KM_BY_SCOPE: Record<ExplorationScope, number> = {
  walkable: 8,
  city_wide: 35,
  spread_out: 120,
};

function validatePlanDayBody(b: RequestBody): string | null {
  if (b.action !== PLAN_DAY_ACTION) return null;
  const dayId = b.day_id?.trim();
  const date = b.date?.trim()?.slice(0, 10);
  const dest = b.destination?.trim();
  if (!dayId || !date || !dest) {
    return "plan_day requires day_id, date, destination";
  }
  const pace = (b.pace ?? "balanced").toLowerCase();
  if (!ALLOWED_PLAN_PACE.has(pace)) return "invalid pace for plan_day";
  const smin = b.stop_count_min;
  const smax = b.stop_count_max;
  if (
    typeof smin !== "number" ||
    typeof smax !== "number" ||
    smin < 1 ||
    smax < smin ||
    smax > 12
  ) {
    return "plan_day requires stop_count_min and stop_count_max (1–12, min ≤ max)";
  }
  const interests = Array.isArray(b.interests) ? b.interests : [];
  if (interests.length > 3) return "plan_day allows at most 3 interests";
  const scope = (b.exploration_scope ?? V2B_DEFAULT_EXPLORATION_SCOPE).toLowerCase();
  if (!ALLOWED_EXPLORATION_SCOPES.has(scope)) {
    return "invalid exploration_scope for plan_day";
  }
  if (!b.time_start?.trim() || !b.time_end?.trim()) {
    return "plan_day requires time_start and time_end";
  }
  const planStayLabel = typeof b.stay_area_label === "string" ? b.stay_area_label.trim() : "";
  const planStayPid = typeof b.stay_area_place_id === "string" ? b.stay_area_place_id.trim() : "";
  if (!planStayLabel) {
    return "plan_day requires stay_area_label (home base / neighborhood for city matching)";
  }
  if (!planStayPid) {
    return "plan_day requires stay_area_place_id (Google place for the base location)";
  }
  return null;
}

async function coordsFromPlaceIdForBias(
  admin: ReturnType<typeof createClient>,
  placeId: string,
): Promise<{ lat: number; lng: number } | null> {
  const pid = placeId.trim();
  if (!pid) return null;
  const { data: pc } = await admin
    .from("place_cache")
    .select("latitude,longitude")
    .eq("place_id", pid)
    .maybeSingle();
  if (pc?.latitude != null && pc?.longitude != null) {
    const lat = Number(pc.latitude);
    const lng = Number(pc.longitude);
    if (Number.isFinite(lat) && Number.isFinite(lng)) return { lat, lng };
  }
  const { data: det } = await cachedPlaceDetails(pid, admin, { skipAiEnrich: true });
  if (!det) return null;
  const geo = det.geometry as Record<string, unknown> | undefined;
  const loc = geo?.location as Record<string, unknown> | undefined;
  const la = loc?.lat;
  const ln = loc?.lng;
  if (typeof la === "number" && typeof ln === "number" && Number.isFinite(la) && Number.isFinite(ln)) {
    return { lat: la, lng: ln };
  }
  if (typeof la === "string" && typeof ln === "string") {
    const x = Number.parseFloat(la);
    const y = Number.parseFloat(ln);
    if (Number.isFinite(x) && Number.isFinite(y)) return { lat: x, lng: y };
  }
  return null;
}

function clampDescription(s: string): string {
  const t = s.trim();
  if (t.length <= MAX_AI_DESCRIPTION_LEN) return t;
  return t.slice(0, MAX_AI_DESCRIPTION_LEN - 1) + "…";
}

function clampMomentLine(s: string): string {
  const t = s.trim();
  if (t.length <= MAX_MOMENT_LINE_LEN) return t;
  return t.slice(0, MAX_MOMENT_LINE_LEN - 1) + "…";
}

function clampStoredDescription(s: string): string {
  const t = s.trim();
  if (t.length <= MAX_STORED_DESCRIPTION_LEN) return t;
  return t.slice(0, MAX_STORED_DESCRIPTION_LEN - 1) + "…";
}

function normWs(s: string): string {
  return s.replace(/\s+/g, " ").trim();
}

/**
 * Hybrid plan_day sets wish-list `reason` on `moment_line` (see matchWishListToPool).
 * If `moment_line` is missing but `description` still has the narrative, recover it so
 * preview ops include `moment_line` for Change 12 UI.
 */
function extractPreviewMomentLine(p: ProposedActivity): string {
  const fromField =
    typeof p.moment_line === "string" ? p.moment_line.trim() : "";
  if (fromField.length > 0) return clampMomentLine(fromField);
  const desc = typeof p.description === "string" ? p.description.trim() : "";
  if (desc.length === 0) return "";
  const first = desc.split(/\n\n+/)[0]!.trim();
  return first.length > 0 ? clampMomentLine(first) : "";
}

/** Body under the editorial moment (avoid storing the moment twice in `description`). */
function practicalDescriptionAfterMoment(p: ProposedActivity, moment: string): string {
  const desc = typeof p.description === "string" ? p.description.trim() : "";
  if (desc.length === 0) return "";
  const m = moment.trim();
  if (m.length === 0) return clampDescription(desc);
  const parts = desc.split(/\n\n+/);
  const first = parts[0]!.trim();
  if (normWs(first) === normWs(m)) {
    const rest = parts.slice(1).join("\n\n").trim();
    return rest.length > 0 ? clampDescription(rest) : "";
  }
  if (normWs(desc) === normWs(m)) return "";
  return clampDescription(desc);
}

function clampStoryTitle(s: string): string {
  const t = s.trim();
  if (t.length <= MAX_STORY_TITLE_LEN) return t;
  return t.slice(0, MAX_STORY_TITLE_LEN - 1) + "…";
}

function clampStorySubtitle(s: string): string {
  const t = s.trim();
  if (t.length <= MAX_STORY_SUBTITLE_LEN) return t;
  return t.slice(0, MAX_STORY_SUBTITLE_LEN - 1) + "…";
}

function sanitizeStoryArc(raw: unknown): string[] | null {
  if (!Array.isArray(raw)) return null;
  const out: string[] = [];
  for (const x of raw) {
    if (typeof x !== "string") continue;
    const t = x.trim().slice(0, MAX_STORY_ARC_LABEL_LEN);
    if (t.length > 0) out.push(t);
    if (out.length >= MAX_STORY_ARC_COUNT) break;
  }
  return out.length > 0 ? out : null;
}

const MAX_PREVIEW_TIPS = 8;
const MAX_PREVIEW_TIP_LEN = 200;
const MAX_PREVIEW_ALTERNATIVES = 2;
const MAX_PREVIEW_ALT_BRIEF_LEN = 400;
const MAX_PREVIEW_NEARBY_MEALS = 5;
const MAX_PREVIEW_PHASE_LABEL_LEN = 80;

function sanitizePreviewTips(raw: unknown): string[] | undefined {
  if (!Array.isArray(raw)) return undefined;
  const out: string[] = [];
  for (const x of raw) {
    if (typeof x !== "string") continue;
    const t = x.trim().slice(0, MAX_PREVIEW_TIP_LEN);
    if (t.length > 0) out.push(t);
    if (out.length >= MAX_PREVIEW_TIPS) break;
  }
  return out.length > 0 ? out : undefined;
}

function sanitizePreviewAlternatives(raw: unknown): ActivityAlternative[] | undefined {
  if (!Array.isArray(raw)) return undefined;
  const out: ActivityAlternative[] = [];
  for (const x of raw) {
    if (!x || typeof x !== "object") continue;
    const o = x as Record<string, unknown>;
    const name = typeof o.name === "string" ? o.name.trim().slice(0, 500) : "";
    const place_id = typeof o.place_id === "string" ? o.place_id.trim() : "";
    if (!name || !place_id) continue;
    const cat = typeof o.category === "string" ? o.category.trim().slice(0, 80) : "other";
    let duration_minutes = 60;
    if (typeof o.duration_minutes === "number" && Number.isFinite(o.duration_minutes)) {
      duration_minutes = Math.max(5, Math.min(480, Math.round(o.duration_minutes)));
    }
    const alt: ActivityAlternative = {
      name,
      place_id,
      category: cat || "other",
      duration_minutes,
    };
    if ("walk_minutes_from_prev" in o) {
      const w = o.walk_minutes_from_prev;
      if (w == null) alt.walk_minutes_from_prev = null;
      else if (typeof w === "number" && Number.isFinite(w)) {
        alt.walk_minutes_from_prev = Math.max(0, Math.min(180, Math.round(w)));
      }
    }
    if (typeof o.brief === "string") {
      const b = o.brief.trim().slice(0, MAX_PREVIEW_ALT_BRIEF_LEN);
      alt.brief = b.length > 0 ? b : null;
    }
    if (typeof o.thumbnail_url === "string") {
      const u = o.thumbnail_url.trim().slice(0, 2000);
      alt.thumbnail_url = u.length > 0 ? u : null;
    }
    const city_place = sanitizeCityPlaceSnapshotForClient(o.city_place);
    if (city_place) alt.city_place = city_place;
    const rawTips = o.tips;
    if (Array.isArray(rawTips)) {
      const tips: string[] = [];
      for (const t of rawTips) {
        if (typeof t !== "string") continue;
        const s = t.trim().slice(0, 200);
        if (s.length > 0) tips.push(s);
        if (tips.length >= 5) break;
      }
      if (tips.length > 0) alt.tips = tips;
    }
    out.push(alt);
    if (out.length >= MAX_PREVIEW_ALTERNATIVES) break;
  }
  return out.length > 0 ? out : undefined;
}

function sanitizePreviewNearbyMeals(raw: unknown): NearbyMealSuggestion[] | undefined {
  if (!Array.isArray(raw)) return undefined;
  const out: NearbyMealSuggestion[] = [];
  for (const x of raw) {
    if (!x || typeof x !== "object") continue;
    const o = x as Record<string, unknown>;
    const name = typeof o.name === "string" ? o.name.trim().slice(0, 500) : "";
    const place_id = typeof o.place_id === "string" ? o.place_id.trim() : "";
    if (!name || !place_id) continue;
    let walk_minutes = 10;
    if (typeof o.walk_minutes === "number" && Number.isFinite(o.walk_minutes)) {
      walk_minutes = Math.max(0, Math.min(180, Math.round(o.walk_minutes)));
    }
    let commute_mode: "walking" | "driving" | "transit" | undefined;
    if (typeof o.commute_mode === "string") {
      const cm = o.commute_mode.trim().toLowerCase();
      if (cm === "walking" || cm === "driving" || cm === "transit") {
        commute_mode = cm;
      }
    }
    let distance_km = 0.5;
    if (typeof o.distance_km === "number" && Number.isFinite(o.distance_km)) {
      distance_km = Math.max(0, Math.min(50, o.distance_km));
    }
    let thumbnail_url: string | undefined;
    if (typeof o.thumbnail_url === "string") {
      const u = o.thumbnail_url.trim().slice(0, 2000);
      if (u.length > 0) thumbnail_url = u;
    }
    let price_level: number | null = null;
    if (typeof o.price_level === "number" && Number.isFinite(o.price_level)) {
      price_level = Math.max(0, Math.min(4, Math.round(o.price_level)));
    }
    let rating: number | undefined;
    if (typeof o.rating === "number" && Number.isFinite(o.rating)) {
      const r = Math.min(5, Math.max(0, Math.round(o.rating * 10) / 10));
      if (r > 0) rating = r;
    }
    let description: string | undefined;
    if (typeof o.description === "string") {
      const d = o.description.trim().slice(0, 280);
      if (d.length > 0) description = d;
    }
    const city_place = sanitizeCityPlaceSnapshotForClient(o.city_place);
    out.push({
      name,
      place_id,
      walk_minutes,
      ...(commute_mode ? { commute_mode } : {}),
      distance_km,
      ...(thumbnail_url ? { thumbnail_url } : {}),
      ...(price_level != null ? { price_level } : {}),
      ...(rating != null ? { rating } : {}),
      ...(description ? { description } : {}),
      ...(city_place ? { city_place } : {}),
    });
    if (out.length >= MAX_PREVIEW_NEARBY_MEALS) break;
  }
  return out.length > 0 ? out : undefined;
}

type PlacesResolve = {
  lat: number;
  lng: number;
  place_id: string;
  address: string;
};

const PLACE_RESOLVE_CONCURRENCY = 5;
const MAX_PLACE_SEARCH_QUERY_LEN = 2000;

async function lookupPlaceCache(
  admin: ReturnType<typeof createClient>,
  placeQuery: string,
  destination: string,
): Promise<PlacesResolve | null> {
  const normalizedName = placeQuery
    .replace(/,\s*/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .toLowerCase();

  const { data: cached } = await admin
    .from("place_cache")
    .select("place_id,name,latitude,longitude,address,fetched_at")
    .or(`name.ilike.%${normalizedName.slice(0, 60)}%`)
    .limit(1);

  if (cached?.length) {
    const c = cached[0];
    if (c.latitude != null && c.longitude != null && c.place_id) {
      logGoogleApiCall("place_resolve", placeQuery, "postgres_hit");
      return {
        lat: c.latitude,
        lng: c.longitude,
        place_id: c.place_id,
        address: c.address ?? "",
      };
    }
  }

  const destLabel = destination.trim().toLowerCase();
  if (!destLabel) return null;

  const { data: existing } = await admin
    .from("trip_activities")
    .select("place_id,latitude,longitude,address")
    .not("place_id", "is", null)
    .not("latitude", "is", null)
    .ilike("name", `%${normalizedName.slice(0, 60)}%`)
    .limit(1);

  if (existing?.length) {
    const e = existing[0];
    if (e.latitude != null && e.longitude != null && e.place_id) {
      logGoogleApiCall("place_resolve", placeQuery, "activities_hit");
      return {
        lat: e.latitude,
        lng: e.longitude,
        place_id: e.place_id,
        address: e.address ?? "",
      };
    }
  }

  logGoogleApiCall("place_resolve", placeQuery, "miss");
  return null;
}

// Phase G.1 — usage recorder. Reads SUPABASE_URL +
// SUPABASE_SERVICE_ROLE_KEY from the function's runtime env (always
// present in production, optional locally), POSTs the event to the
// `record_places_usage_event` RPC, and discards the response. We
// hash the call key with SHA-256 so the raw `places_usage_events`
// table never carries PII or business identifiers — the dashboard
// only needs api/status counts; key_hash exists purely for spotting
// hot keys in forensic audits.
//
// Failures are swallowed: telemetry must never block a real request.
async function recordPlacesUsageEvent(
  api: string,
  key: string,
  status: string,
): Promise<void> {
  try {
    const url = Deno.env.get("SUPABASE_URL");
    const key_role = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!url || !key_role) return;
    const keyHash = await sha256Hex(key);
    await fetch(`${url}/rest/v1/rpc/record_places_usage_event`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "apikey": key_role,
        "Authorization": `Bearer ${key_role}`,
      },
      body: JSON.stringify({
        p_api: api,
        p_status: status,
        p_key_hash: keyHash,
      }),
    });
  } catch (_) {
    // best-effort; never propagate
  }
}

async function sha256Hex(s: string): Promise<string> {
  const buf = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(s),
  );
  return Array.from(new Uint8Array(buf))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function logGoogleApiCall(api: string, key: string, status: string): void {
  safeLog("info", FUNCTION_NAME, "google_api_call", {
    api,
    status,
    lookup_scope: classifyUsageKey(key),
  });
  // Fire-and-forget — never await, never block the caller.
  void recordPlacesUsageEvent(api, key, status);
}

function classifyUsageKey(key: string): string {
  if (key.includes("|")) return "route";
  if (/^-?\d+(\.\d+)?,-?\d+(\.\d+)?$/.test(key)) return "coordinate";
  if (key.length >= 20 && /^[A-Za-z0-9_-]+$/.test(key)) return "place_id";
  return "query";
}

const VALID_TRAVEL_MODES = new Set([
  "driving",
  "walking",
  "transit",
  "bicycling",
]);

/**
 * Phase J.5 — Travel-time lookup with `city_travel_times` Apple-source
 * preference.
 *
 * Resolution order (cheapest, freshest first):
 *   1. `city_travel_times` row for `(cityProfileId, from_place_id, to_place_id)`
 *      where the per-mode `*_provider` is `'apple'`. This is the
 *      output of `upload-travel-leg` (Phase J.2) and is free.
 *   2. Same row, any provider — covers older `mapbox`/`google` rows we
 *      haven't refreshed yet.
 *   3. `cachedDirections` (Google Routes with Redis cache). This is
 *      where the spend lives, so we want it to be the *fallback*, not
 *      the primary lookup.
 *
 * The optional `lookup` arg is what enables the cache hit. Existing
 * call-sites that don't have place_ids (e.g. coordinate-only AI
 * proposals) fall through to step 3 unchanged.
 */
async function distanceLegMinutesCached(
  from: { lat: number; lng: number },
  to: { lat: number; lng: number },
  mode = "driving",
  lookup?: {
    admin: ReturnType<typeof createClient>;
    cityProfileId: string;
    fromPlaceId: string | null | undefined;
    toPlaceId: string | null | undefined;
  } | null,
): Promise<number | null> {
  const m = VALID_TRAVEL_MODES.has(mode) ? mode : "driving";

  if (
    lookup?.admin &&
    lookup.cityProfileId &&
    lookup.fromPlaceId &&
    lookup.toPlaceId
  ) {
    const cached = await readCityTravelTimesLeg(
      lookup.admin,
      lookup.cityProfileId,
      lookup.fromPlaceId,
      lookup.toPlaceId,
      m,
    );
    if (cached != null) {
      logGoogleApiCall(
        "compute_routes",
        `${lookup.fromPlaceId}|${lookup.toPlaceId}|${m}`,
        "city_travel_times_hit",
      );
      return cached;
    }
  }

  logGoogleApiCall(
    "compute_routes",
    `${from.lat},${from.lng}|${to.lat},${to.lng}|${m}`,
    "cached_call",
  );
  const { durationSeconds } = await cachedDirections(from, to, m);
  if (durationSeconds == null) return null;
  return Math.round(durationSeconds / 60);
}

/**
 * Best-effort resolver for the city profile that owns this trip's
 * destination. Returns `null` when we can't tell — callers must
 * gracefully fall back to the unscoped (coordinate-only) path.
 */
async function resolveTripCityProfileId(
  admin: ReturnType<typeof createClient>,
  tripId: string,
): Promise<string | null> {
  type TripRow = { destination_place_id: string | null };
  const { data: trip, error: tripErr } = await admin
    .from("trips")
    .select("destination_place_id")
    .eq("id", tripId)
    .maybeSingle<TripRow>();
  if (tripErr || !trip?.destination_place_id) return null;

  type ProfileRow = { id: string };
  const { data: profile, error: profileErr } = await admin
    .from("city_profiles")
    .select("id")
    .eq("place_id", trip.destination_place_id)
    .maybeSingle<ProfileRow>();
  if (profileErr || !profile?.id) return null;
  return profile.id;
}

/**
 * Single-row lookup against `city_travel_times`. Returns minutes for
 * the requested mode, preferring Apple-sourced data. Returns `null`
 * on miss or when the row only carries a `haversine` value (the
 * caller should fall back to a real router in that case).
 */
async function readCityTravelTimesLeg(
  admin: ReturnType<typeof createClient>,
  cityProfileId: string,
  fromPlaceId: string,
  toPlaceId: string,
  mode: string,
): Promise<number | null> {
  type Row = {
    walking_minutes: number | null;
    driving_minutes: number | null;
    transit_minutes: number | null;
    walking_provider: string | null;
    driving_provider: string | null;
    transit_provider: string | null;
  };
  const { data, error } = await admin
    .from("city_travel_times")
    .select(
      "walking_minutes,driving_minutes,transit_minutes," +
        "walking_provider,driving_provider,transit_provider",
    )
    .eq("city_profile_id", cityProfileId)
    .eq("from_place_id", fromPlaceId)
    .eq("to_place_id", toPlaceId)
    .maybeSingle<Row>();
  if (error || !data) return null;

  const modeColumn = mode === "walking"
    ? { minutes: data.walking_minutes, provider: data.walking_provider }
    : mode === "transit"
    ? { minutes: data.transit_minutes, provider: data.transit_provider }
    : { minutes: data.driving_minutes, provider: data.driving_provider };

  // Skip haversine values — a real router (cachedDirections) will give
  // a better answer and the function call is cheap enough that we'd
  // rather pay for it than hand back a bad estimate.
  if (modeColumn.provider === "haversine") return null;
  if (modeColumn.minutes == null) return null;
  return modeColumn.minutes;
}

function directionsUrl(
  to: { lat: number; lng: number; name?: string },
  mode: string,
  from?: { lat: number; lng: number; name?: string } | null,
  destinationPlaceId?: string | null,
): string {
  const d = to.name?.trim() || `${to.lat},${to.lng}`;
  const m = VALID_TRAVEL_MODES.has(mode) ? mode : "driving";
  const params = new URLSearchParams({
    api: "1",
    destination: d,
    travelmode: m,
  });
  if (destinationPlaceId) {
    params.set("destination_place_id", destinationPlaceId);
  }
  if (from) {
    const origin = from.name?.trim() || `${from.lat},${from.lng}`;
    params.set("origin", origin);
  }
  return `https://www.google.com/maps/dir/?${params.toString()}`;
}

async function fetchTimeZoneIdCached(
  lat: number,
  lng: number,
): Promise<string | null> {
  logGoogleApiCall("timezone", `${lat},${lng}`, "cached_call");
  const { timeZoneId } = await cachedTimezone(lat, lng);
  return timeZoneId;
}

/** Interpret model times as destination wall clock; return ISO UTC for Postgres. */
function normalizeActivityStartsAt(
  dayDate: string,
  p: ProposedActivity,
  zone: string | null,
): string | null {
  const day = dayDate.slice(0, 10);
  const z = zone?.trim() || null;

  if (p.local_time?.trim() && z) {
    const m = /^(\d{1,2}):(\d{2})$/.exec(p.local_time.trim());
    if (m) {
      const h = parseInt(m[1]!, 10);
      const min = parseInt(m[2]!, 10);
      const y = parseInt(day.slice(0, 4), 10);
      const mo = parseInt(day.slice(5, 7), 10);
      const d = parseInt(day.slice(8, 10), 10);
      const dt = DateTime.fromObject(
        { year: y, month: mo, day: d, hour: h, minute: min },
        { zone: z },
      );
      if (dt.isValid) return dt.toUTC().toISO();
    }
  }

  const raw = p.starts_at?.trim();
  if (!raw) return null;
  if (z) {
    const hasExplicitOffset = /([zZ]|[+-]\d{2}:?\d{2})$/.test(raw);
    if (hasExplicitOffset) {
      const dt = DateTime.fromISO(raw, { setZone: true });
      return dt.isValid ? dt.toUTC().toISO() : null;
    }
    const isoish = raw.includes("T") ? raw : `${day}T${raw}`;
    const dt2 = DateTime.fromISO(isoish, { zone: z });
    if (dt2.isValid) return dt2.toUTC().toISO();
  }
  return raw;
}

/** True if the model supplied a usable wall-clock start (preferred: local_time). */
function proposedActivityHasWallClockStart(p: ProposedActivity): boolean {
  if (p.local_time?.trim()) {
    const m = /^(\d{1,2}):(\d{2})$/.exec(p.local_time.trim());
    if (m) {
      const h = parseInt(m[1]!, 10);
      const min = parseInt(m[2]!, 10);
      if (h >= 0 && h <= 23 && min >= 0 && min <= 59) return true;
    }
  }
  const raw = p.starts_at?.trim();
  if (!raw) return false;
  return /T\d{1,2}:\d{2}/.test(raw) || /^(\d{1,2}):(\d{2})/.test(raw);
}

function poolByPlaceIdFromRanked(pool: RankedCandidate[]): Map<string, RankedCandidate> {
  const m = new Map<string, RankedCandidate>();
  for (const c of pool) {
    const id = String(c.place_id ?? "").trim();
    if (id.length > 0) m.set(id, c);
  }
  return m;
}

type PlanHardValidateContext = {
  allowedDayDates: Set<string>;
  poolByPlaceId: Map<string, RankedCandidate>;
  /** Sorted unique YYYY-MM-DD; null skips replace_ai_days checks (NL plan path). */
  replaceRequiredSorted: string[] | null;
};

/**
 * Post-generation checks — do not trust model output alone.
 * When a Text Search pool was used, enforces same-row name/place_id and category vs pool.
 */
function validateProposedPlanHard(
  plan: ParsedPlan,
  ctx: PlanHardValidateContext,
  traceId?: string | null,
): { ok: true } | { ok: false; issues: string[] } {
  const issues: string[] = [];
  const hasPool = ctx.poolByPlaceId.size > 0;

  if (ctx.replaceRequiredSorted != null) {
    const exp = ctx.replaceRequiredSorted;
    const gotUnique = Array.from(
      new Set(
        (plan.replace_ai_days ?? [])
          .map((x) => String(x).trim().slice(0, 10))
          .filter((d) => d.length === 10),
      ),
    ).sort();
    const expSorted = [...exp].sort();
    if (gotUnique.length !== expSorted.length || gotUnique.some((d, i) => d !== expSorted[i])) {
      issues.push(
        `replace_ai_days must contain exactly the dates ${JSON.stringify(expSorted)} (sorted set equality); model had ${JSON.stringify(gotUnique)}`,
      );
    }
  }

  for (let i = 0; i < plan.activities.length; i++) {
    const p = plan.activities[i]!;
    const label = (p.name ?? "").trim() || "?";
    const pref = `activities[${i}] (${label})`;
    const dd = p.day_date?.trim().slice(0, 10) ?? "";
    if (!dd || !ctx.allowedDayDates.has(dd)) {
      issues.push(`${pref}: invalid or disallowed day_date "${p.day_date ?? ""}"`);
    }
    const cat = normalizePlanCategory(p.category);
    if (cat === "transport") {
      continue;
    }
    if (!proposedActivityHasWallClockStart(p)) {
      issues.push(
        `${pref}: non-transport stop missing valid local_time (HH:mm) or equivalent starts_at`,
      );
    }
    if (!hasPool) {
      continue;
    }
    // Restaurants inserted by insertMeals come from the nearbyMeals pool,
    // not the activity candidate pool. Skip pool validation for meal stops.
    if (cat === "restaurant") {
      continue;
    }
    const pid = typeof p.place_id === "string" ? p.place_id.trim() : "";
    if (!pid) {
      issues.push(`${pref}: place_id required when a candidate pool was supplied`);
      continue;
    }
    const row = ctx.poolByPlaceId.get(pid);
    if (!row) {
      issues.push(`${pref}: place_id not found in candidate pool`);
      continue;
    }
    if ((p.name ?? "").trim() !== (row.name ?? "").trim()) {
      issues.push(
        `${pref}: name must exactly match pool row for this place_id (anti-stitching)`,
      );
    }
    const poolCat = normalizePlanCategory(row.wayfind_category);
    if (cat !== poolCat) {
      // Category mismatch is a soft warning, not a hard failure.
      // The model's category judgment (e.g., "attraction" for 9/11 Memorial) is often
      // more accurate than the pool's inferred category (e.g., "nature" because Google
      // types included "park"). The critical checks are name + place_id anti-stitching.
      if (traceId) {
        logItineraryAiStep(
          traceId,
          "journey_hybrid_category_pool_mismatch",
          {
            activity_index: i,
            activity_label: label,
            model_category: cat,
            pool_category: poolCat,
          },
          "warn",
        );
      } else {
        console.warn(
          `[itinerary-ai] ${pref}: category "${cat}" differs from pool ("${poolCat}") — accepting model's choice`,
        );
      }
    }
  }

  return issues.length === 0 ? { ok: true } : { ok: false, issues };
}

/** Parse "HH:mm" or "H:mm" → minutes from midnight; null if invalid. */
function parsePlanDayClockToMinutes(hhmm: string): number | null {
  const m = /^(\d{1,2}):(\d{2})$/.exec(hhmm.trim());
  if (!m) return null;
  const h = parseInt(m[1]!, 10);
  const min = parseInt(m[2]!, 10);
  if (h > 23 || min > 59 || h < 0 || min < 0) return null;
  return h * 60 + min;
}

/**
 * When the model omits local_time or timezone was unknown during resolve, lay out stops in order
 * inside the user's plan_day window (time_start–time_end), using duration_minutes and a small gap.
 */
function fillMissingPlanDayStartsAt(
  list: Array<{
    name: string;
    description: string;
    category: string;
    starts_at: string | null;
    duration_minutes: number | null;
  }>,
  dayDate: string,
  zone: string | null,
  windowStart: string,
  windowEnd: string,
): void {
  if (!zone || list.length === 0) return;
  const w0 = parsePlanDayClockToMinutes(windowStart);
  const w1 = parsePlanDayClockToMinutes(windowEnd);
  if (w0 == null || w1 == null || w1 <= w0) return;

  const DEFAULT_GAP_MIN = 15;
  let cursor = w0;

  for (const row of list) {
    const dur =
      row.duration_minutes != null && row.duration_minutes > 0
        ? row.duration_minutes
        : 60;

    if (row.starts_at) {
      const dt = DateTime.fromISO(row.starts_at, { setZone: true });
      if (!dt.isValid) continue;
      const local = dt.setZone(zone);
      if (!local.isValid) continue;
      const startM = local.hour * 60 + local.minute;
      const endM = startM + dur;
      cursor = Math.max(cursor, endM + DEFAULT_GAP_MIN);
      continue;
    }

    let startM = cursor;
    if (startM + dur > w1) {
      startM = Math.max(w0, w1 - dur);
    }
    const hh = Math.floor(startM / 60);
    const mm = startM % 60;
    const local_time =
      `${String(hh).padStart(2, "0")}:${String(mm).padStart(2, "0")}`;
    row.starts_at = normalizeActivityStartsAt(
      dayDate,
      {
        day_date: dayDate,
        name: row.name,
        description: row.description,
        category: row.category,
        local_time,
      },
      zone,
    );
    cursor = startM + dur + DEFAULT_GAP_MIN;
  }
}

type LegActivityRow = {
  id: string;
  day_id: string;
  sort_order: number;
  latitude: number | null;
  longitude: number | null;
  place_id: string | null;
  name: string;
  travel_mode: string;
};

async function recomputeLegsForTrip(
  admin: ReturnType<typeof createClient>,
  tripId: string,
  traceId?: string | null,
): Promise<{ updated: number }> {
  const { data: daysRaw, error: daysErr } = await admin
    .from("trip_days")
    .select("id,date")
    .eq("trip_id", tripId)
    .order("date", { ascending: true });

  if (daysErr) {
    throw new Error(daysErr.message);
  }

  const { data: actData, error: actErr } = await admin
    .from("trip_activities")
    .select("id,day_id,sort_order,latitude,longitude,place_id,name,travel_mode")
    .eq("trip_id", tripId);

  if (actErr) {
    throw new Error(actErr.message);
  }

  const acts = (actData ?? []) as LegActivityRow[];
  const byDay = new Map<string, LegActivityRow[]>();
  for (const a of acts) {
    const list = byDay.get(a.day_id) ?? [];
    list.push(a);
    byDay.set(a.day_id, list);
  }

  for (const [, list] of byDay) {
    list.sort((a, b) => {
      if (a.sort_order !== b.sort_order) return a.sort_order - b.sort_order;
      return a.id.localeCompare(b.id);
    });
  }

  const sortedDays = [...(daysRaw ?? [])] as { id: string; date: string }[];
  sortedDays.sort((a, b) => a.date.localeCompare(b.date));

  // Phase J.5 — pull the trip's city_profile_id once so each leg can
  // try its `city_travel_times` row before falling back to Google
  // Routes. Best-effort; missing profile just means we use the same
  // path as before (cachedDirections).
  const cityProfileId = await resolveTripCityProfileId(admin, tripId);

  for (const day of sortedDays) {
    const list = byDay.get(day.id);
    if (!list?.length) continue;
    for (let i = 0; i < list.length; i++) {
      const cur = list[i]!;
      const mode = cur.travel_mode || "driving";
      let travelMin: number | null = null;
      let dirUrl: string | null = null;
      const prev = i > 0 ? list[i - 1]! : null;
      if (cur.latitude != null && cur.longitude != null) {
        const fromArg = prev?.latitude != null && prev?.longitude != null
          ? { lat: prev.latitude!, lng: prev.longitude!, name: prev.name }
          : null;
        dirUrl = directionsUrl(
          { lat: cur.latitude, lng: cur.longitude, name: cur.name },
          mode,
          fromArg,
          cur.place_id,
        );
      }
      if (prev?.latitude != null && prev?.longitude != null &&
          cur.latitude != null && cur.longitude != null) {
        travelMin = await distanceLegMinutesCached(
          { lat: prev!.latitude!, lng: prev!.longitude! },
          { lat: cur.latitude!, lng: cur.longitude! },
          mode,
          cityProfileId
            ? {
                admin,
                cityProfileId,
                fromPlaceId: prev?.place_id,
                toPlaceId: cur.place_id,
              }
            : null,
        );
      }
      const { error: upErr } = await admin.from("trip_activities").update({
        travel_from_previous_minutes: travelMin,
        directions_url: dirUrl,
      }).eq("id", cur.id).eq("trip_id", tripId);
      if (upErr) {
        if (traceId) {
          logItineraryAiStep(
            traceId,
            "recompute_leg_db_update",
            { message: upErr.message, activity_id: cur.id },
            "error",
          );
        } else {
          console.error("[itinerary-ai] leg update", upErr.message);
        }
      }
    }
  }

  return { updated: acts.length };
}

serve(async (req: Request) => {
  initSentry();

  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }

  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), {
      status: 405,
      headers: CORS_HEADERS,
    });
  }

  const traceId = crypto.randomUUID();
  const audit: ItineraryAiAuditBase = {
    trace_id: traceId,
    user_id: null,
    trip_id: null,
    action: "",
  };

  try {
    const step = (
      where: string,
      extra?: Record<string, unknown>,
      level: "log" | "warn" | "error" = "log",
    ) => logItineraryAiStep(audit.trace_id, where, extra, level);

    step("journey_begin", {});

    const authHeader = req.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) {
      step("journey_auth_failed", { reason: "missing_bearer" }, "warn");
      return jsonResponseWithAudit(
        audit,
        { error: "Unauthorized" },
        401,
        CORS_HEADERS,
      );
    }

    const supabaseUser = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    });

    const { data: userData, error: userErr } = await supabaseUser.auth
      .getUser();
    const user = userData?.user;
    if (userErr || !user?.id) {
      step(
        "journey_auth_failed",
        {
          reason: "invalid_user",
          auth_error: userErr?.message ?? null,
        },
        "warn",
      );
      return jsonResponseWithAudit(
        audit,
        { error: "Unauthorized" },
        401,
        CORS_HEADERS,
      );
    }

    audit.user_id = user.id;
    step("journey_auth_ok", { user_id: user.id });

    const body = (await req.json()) as RequestBody;
    const action = body.action ?? "";
    audit.action = action;
    audit.trip_id =
      typeof body.trip_id === "string" && body.trip_id.trim().length > 0
        ? body.trip_id.trim()
        : null;

    step("journey_body_parsed", { action: action || null });

    const respond = (payload: unknown, status: number) =>
      jsonResponseWithAudit(audit, payload, status, CORS_HEADERS);

    const startExtra: Record<string, unknown> = {};
    if (action === PLAN_DAY_ACTION) {
      startExtra.preview_only = Boolean(body.preview_only);
      startExtra.day_id = typeof body.day_id === "string" ? body.day_id : null;
      const planDate =
        typeof body.date === "string" ? body.date.trim().slice(0, 10) : null;
      if (planDate) startExtra.plan_date = planDate;

      const destRaw =
        typeof body.destination === "string" ? body.destination.trim() : "";
      startExtra.destination =
        destRaw.length > 140 ? `${destRaw.slice(0, 140)}…` : destRaw;

      startExtra.pace = typeof body.pace === "string" ? body.pace : null;
      startExtra.travel_style =
        typeof body.travel_style === "string" ? body.travel_style : null;
      startExtra.exploration_scope =
        typeof body.exploration_scope === "string"
          ? body.exploration_scope.trim().toLowerCase()
          : null;
      const tripDepth = (body as { trip_depth?: string }).trip_depth;
      startExtra.trip_depth =
        typeof tripDepth === "string" ? tripDepth.trim() : null;

      startExtra.interests = Array.isArray(body.interests)
        ? body.interests
          .filter((x): x is string => typeof x === "string" && x.trim().length > 0)
          .map((s) => s.trim())
          .slice(0, 6)
        : [];

      startExtra.stop_count_min =
        typeof body.stop_count_min === "number" ? body.stop_count_min : null;
      startExtra.stop_count_max =
        typeof body.stop_count_max === "number" ? body.stop_count_max : null;
      startExtra.time_start =
        typeof body.time_start === "string" ? body.time_start.trim() : null;
      startExtra.time_end =
        typeof body.time_end === "string" ? body.time_end.trim() : null;
      startExtra.include_meals = body.include_meals !== false;

      const stayLabelRaw =
        typeof body.stay_area_label === "string" ? body.stay_area_label.trim() : "";
      startExtra.stay_area_label =
        stayLabelRaw.length > 120 ? `${stayLabelRaw.slice(0, 120)}…` : stayLabelRaw;
      const stayPidRaw =
        typeof body.stay_area_place_id === "string"
          ? body.stay_area_place_id.trim()
          : "";
      startExtra.stay_area_place_id = stayPidRaw.length > 0 ? stayPidRaw : null;

      const ex = Array.isArray(body.exclude_places) ? body.exclude_places : [];
      const exStr = ex
        .filter((x): x is string => typeof x === "string" && x.trim().length > 0)
        .map((s) => s.trim());
      startExtra.exclude_places_count = exStr.length;
      startExtra.exclude_places_sample = exStr.slice(0, 14);
    } else if (action === REPORT_PLACE_ACTION) {
      startExtra.report_place_id =
        typeof body.place_id === "string" ? body.place_id.trim() : null;
      startExtra.report_city_profile_id =
        typeof body.city_profile_id === "string"
          ? body.city_profile_id.trim()
          : null;
      const rsn =
        typeof body.reason === "string" ? body.reason.trim().slice(0, 120) : "";
      startExtra.report_reason = rsn.length > 0 ? rsn : null;
    }
    logItineraryAiStart(audit, startExtra);

    if (action === REPORT_PLACE_ACTION) {
      const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
      const placeId =
        typeof body.place_id === "string" ? body.place_id.trim() : "";
      const cityProfileId =
        typeof body.city_profile_id === "string"
          ? body.city_profile_id.trim()
          : "";
      if (!placeId || !cityProfileId) {
        return respond(
          {
            error: "place_id and city_profile_id are required",
          },
          400,
        );
      }

      const { data: place, error: selErr } = await admin
        .from("city_places")
        .select("reported_count,status")
        .eq("city_profile_id", cityProfileId)
        .eq("place_id", placeId)
        .maybeSingle();

      if (selErr) {
        step("journey_report_place_select_failed", { message: selErr.message }, "error");
        return respond(
          { error: "report_failed", detail: selErr.message },
          500,
        );
      }
      if (!place) {
        return respond({ error: "Place not found" }, 404);
      }

      const currentStatus = String(place.status ?? "active");
      if (currentStatus === "removed") {
        return respond(
          {
            ok: true,
            new_status: "removed",
            reported_count: place.reported_count ?? 0,
            note: "already_removed",
          },
          200,
        );
      }

      const newCount = (place.reported_count ?? 0) + 1;
      const newStatus = newCount >= 3 ? "removed" : "reported";

      const { error: upErr } = await admin
        .from("city_places")
        .update({
          reported_count: newCount,
          reported_at: new Date().toISOString(),
          status: newStatus,
        })
        .eq("city_profile_id", cityProfileId)
        .eq("place_id", placeId);

      if (upErr) {
        step("journey_report_place_update_failed", { message: upErr.message }, "error");
        return respond(
          { error: "report_failed", detail: upErr.message },
          500,
        );
      }

      const reason =
        typeof body.reason === "string" && body.reason.trim().length > 0
          ? body.reason.trim().slice(0, 200)
          : undefined;
      if (reason) {
        console.log(
          `[itinerary-ai] report_place user=${user.id} place=${placeId} profile=${cityProfileId} reason=${reason}`,
        );
      }

      step("journey_report_place_ok", {
        place_id: placeId,
        city_profile_id: cityProfileId,
        new_status: newStatus,
        reported_count: newCount,
      });
      return respond(
        {
          ok: true,
          new_status: newStatus,
          reported_count: newCount,
        },
        200,
      );
    }

    const tripId = body.trip_id?.trim();
    if (!tripId) {
      step("journey_gate_failed", { gate: "trip_id", error: "trip_id is required" }, "warn");
      return respond({ error: "trip_id is required" }, 400);
    }

    audit.trip_id = tripId;

    const planDayErr = validatePlanDayBody(body);
    if (planDayErr) {
      step(
        "journey_gate_failed",
        { gate: "plan_day_body", error: planDayErr },
        "warn",
      );
      return respond({ error: planDayErr }, 400);
    }

    const utilityOrStructured =
      action === "recompute_legs" ||
      action === "compute_leg" ||
      action === "resolve_timezone" ||
      action === PLAN_DAY_ACTION ||
      action === APPLY_PLAN_DAY_OPS_ACTION ||
      action === REPORT_PLACE_ACTION;

    if (!utilityOrStructured) {
      step(
        "journey_gate_failed",
        { gate: "action", error: "unknown action", action },
        "warn",
      );
      return respond({ error: "unknown action" }, 400);
    }

    const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    const { data: canEdit, error: editErr } = await admin.rpc(
      "is_trip_editor",
      { p_trip_id: tripId, p_user_id: user.id },
    );
    if (editErr || !canEdit) {
      step(
        "journey_gate_failed",
        {
          gate: "is_trip_editor",
          rpc_error: editErr?.message ?? null,
          can_edit: canEdit === true,
        },
        "warn",
      );
      return respond({ error: "Forbidden" }, 403);
    }

    step("journey_editor_ok", { trip_id: tripId });

    if (action === APPLY_PLAN_DAY_OPS_ACTION) {
      const rawOps = body.itinerary_ops;
      if (!Array.isArray(rawOps) || rawOps.length === 0) {
        step(
          "journey_gate_failed",
          { gate: "apply_plan_day_ops_empty_ops" },
          "warn",
        );
        return respond(
          { error: "itinerary_ops must be a non-empty array" },
          400,
        );
      }
      if (rawOps.length > 48) {
        step(
          "journey_gate_failed",
          { gate: "apply_plan_day_ops_too_many", op_count: rawOps.length },
          "warn",
        );
        return respond({ error: "too many itinerary_ops" }, 400);
      }

      step("journey_apply_preview_ops_begin", { op_count: rawOps.length });

      const { error: applyRpcErr } = await admin.rpc("apply_itinerary_ops", {
        p_trip_id: tripId,
        p_actor_id: user.id,
        p_payload: { ops: rawOps },
      });

      if (applyRpcErr) {
        step("journey_apply_preview_ops_failed", { message: applyRpcErr.message }, "error");
        return respond(
          {
            error: "Failed to apply itinerary",
            detail: applyRpcErr.message,
          },
          500,
        );
      }

      step("journey_apply_preview_ops_ok", { applied_ops: rawOps.length });
      return respond(
        {
          ok: true,
          applied_ops: rawOps.length,
          summary: "Plan added to your timeline.",
        },
        200,
      );
    }

    if (action === "recompute_legs") {
      try {
        step("journey_recompute_legs_begin", {});
        const { updated } = await recomputeLegsForTrip(
          admin,
          tripId,
          audit.trace_id,
        );
        step("journey_recompute_legs_ok", { activities_touched: updated });
        return respond(
          {
            ok: true,
            recompute_legs: true,
            activities_touched: updated,
            google_routes_enabled: Boolean(GOOGLE_MAPS_API_KEY),
          },
          200,
        );
      } catch (e) {
        step(
          "journey_recompute_legs_failed",
          {
            message: e instanceof Error ? e.message : String(e),
          },
          "error",
        );
        return respond(
          {
            error: e instanceof Error ? e.message : "recompute_legs failed",
          },
          500,
        );
      }
    }

    if (action === "compute_leg") {
      try {
        step("journey_compute_leg_begin", {});
        const fromPt = body.from;
        const toPt = body.to;
        if (!toPt || typeof toPt.lat !== "number" || typeof toPt.lng !== "number") {
          step(
            "journey_gate_failed",
            { gate: "compute_leg_to_point" },
            "warn",
          );
          return respond(
            { error: "to {lat, lng} is required for compute_leg" },
            400,
          );
        }

        const ALL_MODES = ["driving", "walking", "transit", "bicycling"] as const;
        const hasFrom = fromPt && typeof fromPt.lat === "number" && typeof fromPt.lng === "number";

        const requestedMode = body.mode;
        const singleMode = typeof requestedMode === "string" && VALID_TRAVEL_MODES.has(requestedMode)
          ? requestedMode
          : null;
        const distanceModes = singleMode ? [singleMode] : (ALL_MODES as unknown as string[]);

        const modes: Record<string, { minutes: number | null; directions_url: string }> = {};

        for (const mode of ALL_MODES) {
          const dirUrl = directionsUrl(
            { lat: toPt.lat, lng: toPt.lng, name: toPt.name },
            mode,
            hasFrom ? { lat: fromPt!.lat, lng: fromPt!.lng, name: fromPt!.name } : null,
            toPt.place_id,
          );
          modes[mode] = { minutes: null, directions_url: dirUrl };
        }

        const distanceResults = await Promise.all(
          distanceModes.map(async (mode) => {
            let minutes: number | null = null;
            if (hasFrom) {
              minutes = await distanceLegMinutesCached(
                { lat: fromPt!.lat, lng: fromPt!.lng },
                { lat: toPt.lat, lng: toPt.lng },
                mode,
              );
            }
            return { mode, minutes };
          }),
        );
        for (const r of distanceResults) {
          modes[r.mode].minutes = r.minutes;
        }

        step("journey_compute_leg_ok", { mode_count: Object.keys(modes).length });
        return respond({ ok: true, modes }, 200);
      } catch (e) {
        step(
          "journey_compute_leg_failed",
          { message: e instanceof Error ? e.message : String(e) },
          "error",
        );
        return respond(
          {
            error: e instanceof Error ? e.message : "compute_leg failed",
          },
          500,
        );
      }
    }

    if (action === "resolve_timezone") {
      try {
        step("journey_resolve_timezone_begin", {});
        const { data: trip } = await admin
          .from("trips")
          .select("destination_place_id, display_timezone, destinations")
          .eq("id", tripId)
          .single();

        if (trip?.display_timezone) {
          step("journey_resolve_timezone_ok", {
            timezone: trip.display_timezone,
            source: "trip_row_cached",
          });
          return respond({ ok: true, timezone: trip.display_timezone }, 200);
        }

        const tzPlaceId: string | null =
          (trip?.destination_place_id as string) ??
          ((trip?.destinations as Array<{ place_id: string | null }> | null)?.[0]?.place_id ?? null);

        let coords: { lat: number; lng: number } | null = null;

        if (tzPlaceId) {
          const { data: cached } = await admin
            .from("place_cache")
            .select("latitude,longitude")
            .eq("place_id", tzPlaceId)
            .maybeSingle();
          if (cached?.latitude != null && cached?.longitude != null) {
            coords = { lat: cached.latitude, lng: cached.longitude };
          }
        }

        if (!coords) {
          const { data: act } = await admin
            .from("trip_activities")
            .select("latitude,longitude")
            .eq("trip_id", tripId)
            .not("latitude", "is", null)
            .not("longitude", "is", null)
            .limit(1);
          if (act?.length && act[0].latitude != null && act[0].longitude != null) {
            coords = { lat: act[0].latitude, lng: act[0].longitude };
          }
        }

        if (!coords) {
          step("journey_resolve_timezone_ok", {
            timezone: null,
            source: "no_coordinates",
          });
          return respond({ ok: true, timezone: null }, 200);
        }

        const tz = await fetchTimeZoneIdCached(coords.lat, coords.lng);
        if (tz) {
          await admin
            .from("trips")
            .update({ display_timezone: tz })
            .eq("id", tripId);
        }

        step("journey_resolve_timezone_ok", { timezone: tz ?? null });
        return respond({ ok: true, timezone: tz }, 200);
      } catch (e) {
        step(
          "journey_resolve_timezone_failed",
          { message: e instanceof Error ? e.message : String(e) },
          "error",
        );
        return respond(
          {
            error: e instanceof Error ? e.message : "resolve_timezone failed",
          },
          500,
        );
      }
    }

    if (!OPENAI_API_KEY) {
      step(
        "journey_blocked",
        { reason: "openai_api_key_missing", action },
        "error",
      );
      return respond({ error: "OPENAI_API_KEY not configured" }, 500);
    }

    step("journey_trip_load_begin", { trip_id: tripId });
    const { data: trip, error: tripErr } = await admin
      .from("trips")
      .select(
        "id,name,destination,destination_place_id,start_date,end_date,user_id,destinations,display_timezone",
      )
      .eq("id", tripId)
      .single();

    if (tripErr || !trip) {
      step(
        "journey_gate_failed",
        {
          gate: "trip_row",
          error: "Trip not found",
          trip_fetch_error: tripErr?.message ?? null,
        },
        "warn",
      );
      return respond({ error: "Trip not found" }, 404);
    }

    const tripName =
      typeof trip.name === "string" ? trip.name.trim().slice(0, 80) : null;
    step("journey_trip_loaded", {
      trip_id: tripId,
      trip_name: tripName,
      destination: String(trip.destination ?? "").trim().slice(0, 100),
    });

    type TripDestinationRow = {
      label: string;
      place_id: string | null;
      start_date: string;
      end_date: string;
    };

    function parseDestinationsColumn(raw: unknown): TripDestinationRow[] | null {
      if (raw == null) return null;
      if (Array.isArray(raw)) return raw as TripDestinationRow[];
      if (typeof raw === "string") {
        try {
          const p = JSON.parse(raw) as unknown;
          return Array.isArray(p) ? (p as TripDestinationRow[]) : null;
        } catch {
          return null;
        }
      }
      return null;
    }

    function dateOnlyFromDb(v: unknown): string {
      if (v == null) return "";
      const s = String(v).trim();
      return s.length >= 10 ? s.slice(0, 10) : s;
    }

    const parsedCols = parseDestinationsColumn(trip.destinations);
    const tripDestinations: TripDestinationRow[] =
      parsedCols != null && parsedCols.length > 0
        ? parsedCols.map((row) => ({
          label: String(row.label ?? "").trim() || String(trip.destination ?? ""),
          place_id: row.place_id ?? null,
          start_date: dateOnlyFromDb(row.start_date),
          end_date: dateOnlyFromDb(row.end_date),
        }))
        : [{
            label: String(trip.destination ?? ""),
            place_id: (trip.destination_place_id as string) ?? null,
            start_date: dateOnlyFromDb(trip.start_date),
            end_date: dateOnlyFromDb(trip.end_date),
          }];

    const { data: daysRaw, error: daysErr } = await admin
      .from("trip_days")
      .select("id,date,label")
      .eq("trip_id", tripId)
      .order("date", { ascending: true });

    if (daysErr) {
      step(
        "journey_gate_failed",
        { gate: "trip_days", message: daysErr.message },
        "error",
      );
      return respond({ error: "Failed to load days" }, 500);
    }

    let days = (daysRaw ?? []) as DayRow[];
    if (body.date_from) {
      const from = body.date_from.slice(0, 10);
      days = days.filter((d) => d.date >= from);
    }
    if (body.date_to) {
      const to = body.date_to.slice(0, 10);
      days = days.filter((d) => d.date <= to);
    }

    if (action === PLAN_DAY_ACTION) {
      const did = body.day_id!.trim();
      const ddate = body.date!.trim().slice(0, 10);
      days = days.filter((d) => d.id === did);
      if (!days.length || days[0].date.slice(0, 10) !== ddate) {
        step(
          "journey_gate_failed",
          {
            gate: "plan_day_day_match",
            day_id: did,
            plan_date: ddate,
            matched: false,
          },
          "warn",
        );
        return respond(
          {
            error:
              "plan_day: day_id or date does not match a trip day in range",
          },
          400,
        );
      }
    }

    if (!days.length) {
      step(
        "journey_gate_failed",
        {
          gate: "trip_days_in_range",
          error: "no_days_in_range",
          date_from: body.date_from?.slice(0, 10) ?? null,
          date_to: body.date_to?.slice(0, 10) ?? null,
        },
        "warn",
      );
      return respond(
        {
          error:
            "No itinerary days in the selected range. Set trip dates or widen the range.",
        },
        400,
      );
    }

    step("journey_trip_days_ready", {
      day_count: days.length,
      date_from: body.date_from?.slice(0, 10) ?? null,
      date_to: body.date_to?.slice(0, 10) ?? null,
    });

    const aiFeature = "ai_day_planner";
    const monthlyLimit = V2B_MONTHLY_LIMIT_AI_DAY_PLANNER;

    const dayIds = days.map((d) => d.id);
    let activities: ActivityRow[] = [];
    if (dayIds.length) {
      const { data: actData } = await admin
        .from("trip_activities")
        .select(
          "id,day_id,source,name,description,starts_at,sort_order,latitude,longitude",
        )
        .eq("trip_id", tripId)
        .in("day_id", dayIds);
      activities = (actData ?? []) as ActivityRow[];
    }

    if (action === PLAN_DAY_ACTION) {
      step("journey_activities_snapshot", {
        activity_row_count: activities.length,
        day_ids_in_scope: dayIds.length,
      });
    }

    type EnrichedDestination = {
      label: string;
      place_id: string | null;
      startDate: string;
      endDate: string;
      lat: number | null;
      lng: number | null;
      timeZoneId: string | null;
    };

    function destinationForDay(
      dayDate: string,
      list: EnrichedDestination[],
    ): EnrichedDestination | null {
      const d = dayDate.slice(0, 10);
      for (const row of list) {
        if (!row.startDate || !row.endDate) continue;
        if (d >= row.startDate && d <= row.endDate) return row;
      }
      return null;
    }

    const tripStoredTz =
      typeof trip.display_timezone === "string" && trip.display_timezone.trim().length > 0
        ? trip.display_timezone.trim()
        : null;

    const enrichedDestinations: EnrichedDestination[] = [];

    for (const dest of tripDestinations) {
      let coords: { lat: number; lng: number } | null = null;

      if (dest.place_id) {
        const { data: cached } = await admin
          .from("place_cache")
          .select("latitude,longitude")
          .eq("place_id", dest.place_id)
          .maybeSingle();
        if (cached?.latitude != null && cached?.longitude != null) {
          coords = { lat: cached.latitude, lng: cached.longitude };
        }
      }

      enrichedDestinations.push({
        label: dest.label,
        place_id: dest.place_id,
        startDate: dest.start_date,
        endDate: dest.end_date,
        lat: coords?.lat ?? null,
        lng: coords?.lng ?? null,
        /** Filled from trip.display_timezone and/or inferred from destination coordinates. */
        timeZoneId: tripStoredTz,
      });
    }

    let displayTz: string | null = tripStoredTz;
    if (!displayTz) {
      for (const d of enrichedDestinations) {
        if (d.lat != null && d.lng != null) {
          const inferred = await fetchTimeZoneIdCached(d.lat, d.lng);
          if (inferred) {
            displayTz = inferred;
            break;
          }
        }
      }
    }
    if (displayTz) {
      for (const d of enrichedDestinations) {
        d.timeZoneId = displayTz;
      }
    }

    /** Change 1: prompt uses base / day planner destination — not abstract trip.destination (e.g. country). */
    const stayAreaTrim =
      typeof body.stay_area_label === "string" ? body.stay_area_label.trim() : "";
    const planDayDestinationTrim =
      action === PLAN_DAY_ACTION && typeof body.destination === "string"
        ? body.destination.trim()
        : "";
    let cityProfile: CityProfile | null = null;
    let effectiveCitySearchLabel = "";
    /**
     * `plan_day` geographic anchor: stay_area_place_id first, then that day's trip
     * destination coords, then first trip destination. Used for `matchCityProfile` and
     * (same as pool center / hybrid TTDP) so wish-list `|km` and ranking match the home base.
     */
    let planDayGeoCenter: { lat: number; lng: number } | null = null;

    if (action === PLAN_DAY_ACTION) {
      const stayPidForCenter = String(body.stay_area_place_id ?? "").trim();
      if (stayPidForCenter.length > 0) {
        planDayGeoCenter = await coordsFromPlaceIdForBias(admin, stayPidForCenter);
      }
      if (!planDayGeoCenter && action === PLAN_DAY_ACTION && typeof body.date === "string") {
        const planDayDateKey = body.date.trim().slice(0, 10);
        const planDayDestRow = destinationForDay(planDayDateKey, enrichedDestinations);
        if (planDayDestRow?.lat != null && planDayDestRow?.lng != null) {
          planDayGeoCenter = { lat: planDayDestRow.lat, lng: planDayDestRow.lng };
        }
      }
      if (!planDayGeoCenter) {
        const firstDest = enrichedDestinations[0];
        if (firstDest?.lat != null && firstDest?.lng != null) {
          planDayGeoCenter = { lat: firstDest.lat, lng: firstDest.lng };
        }
      }

      if (planDayGeoCenter) {
        cityProfile = await matchCityProfile(admin, planDayGeoCenter, stayAreaTrim);
      }

      if (cityProfile) {
        effectiveCitySearchLabel = cityProfile.city_search_label.trim();
      } else {
        const labelForDerive =
          stayAreaTrim ||
          (action === PLAN_DAY_ACTION
            ? planDayDestinationTrim
            : String(body.destination ?? "").trim());
        effectiveCitySearchLabel =
          deriveCityLabel(labelForDerive).trim() || labelForDerive.trim();
      }

      step("journey_city_profile", {
        matched: cityProfile != null,
        city_profile_id: cityProfile?.id ?? null,
        plan_day_geo_center:
          planDayGeoCenter != null
            ? { lat: planDayGeoCenter.lat, lng: planDayGeoCenter.lng }
            : null,
        effective_city_search_label: effectiveCitySearchLabel.trim().slice(0, 120),
        display_timezone: displayTz,
      });
    }

    const excludePlaceNames = (Array.isArray(body.exclude_places) ? body.exclude_places : [])
      .map((x) => (typeof x === "string" ? x.trim() : ""))
      .filter((s) => s.length > 0);

    let hybridIndexedActivityPool: CityPlaceDbRow[] | undefined;
    let planDayHybridAnchor: { lat: number; lng: number } | null = null;
    let planDayHybridCityLabel = "";
    let planDayHybridDestQuery = "";
    let poolByPlaceId = new Map<string, RankedCandidate>();
    const canBuildPlanDayPool =
      action === PLAN_DAY_ACTION &&
      (!!GOOGLE_MAPS_API_KEY || !!cityProfile?.id);

    if (canBuildPlanDayPool) {
      try {
        const ddate = body.date!.trim().slice(0, 10);
        const destRow = destinationForDay(ddate, enrichedDestinations);
        const label = destRow?.label?.trim() || body.destination!.trim();
        const center =
          planDayGeoCenter ??
          (destRow?.lat != null && destRow?.lng != null
            ? { lat: destRow.lat, lng: destRow.lng }
            : null);
        step("journey_pool_geo_center", {
          lat: center?.lat ?? null,
          lng: center?.lng ?? null,
          used_plan_day_geo_center: planDayGeoCenter != null,
        });
        const explorationScope = normalizeExplorationScope(body.exploration_scope);
        const baseLabelForPool =
          stayAreaTrim.length > 0
            ? stayAreaTrim
            : planDayDestinationTrim.length > 0
            ? planDayDestinationTrim
            : label;
        const citySearchForPool =
          effectiveCitySearchLabel.trim() ||
          deriveCityLabel(baseLabelForPool).trim() ||
          label.trim();
        const profileOrDefault = cityProfile ?? buildDefaultProfile(baseLabelForPool);
        const searchRadiusM = getProfileRadius(profileOrDefault, explorationScope);
        const distCapKm = getProfileDistCap(profileOrDefault, explorationScope);
        const clusterRadiusKm = profileOrDefault.cluster_radius_km;
        const poolResult = await fetchPlanDayCandidatePool({
          destinationLabel: label,
          baseLabel: baseLabelForPool,
          citySearchLabel: citySearchForPool,
          center,
          interests: Array.isArray(body.interests) ? body.interests : [],
          includeMeals: body.include_meals !== false,
          timeStart: body.time_start!.trim(),
          timeEnd: body.time_end!.trim(),
          scope: explorationScope,
          searchRadiusM,
          distCapKm,
          clusterRadiusKm,
          cityProfileId: cityProfile?.id ?? null,
          anchorPlaces: [],
          admin,
          excludePlaces: excludePlaceNames,
        });
        const { allCandidates, searchCenter: poolSearchCenter } = poolResult;
        hybridIndexedActivityPool = poolResult.hybridIndexedActivityPool;
        if (poolSearchCenter) {
          planDayHybridAnchor = poolSearchCenter;
        }
        planDayHybridCityLabel = citySearchForPool;
        planDayHybridDestQuery = baseLabelForPool;
        if (allCandidates.length > 0) {
          poolByPlaceId = poolByPlaceIdFromRanked(allCandidates);
        }
        step("journey_candidate_pool_ok", {
          ranked_candidates: allCandidates.length,
          hybrid_indexed_pool: hybridIndexedActivityPool?.length ?? 0,
          pool_place_ids: poolByPlaceId.size,
          exploration_scope: explorationScope,
        });
      } catch (e) {
        step(
          "journey_candidate_pool_failed",
          { message: e instanceof Error ? e.message : String(e) },
          "error",
        );
      }
    }

    const allowedDayDates = new Set(days.map((d) => d.date.slice(0, 10)));
    const replaceRequiredSorted = [body.date!.trim().slice(0, 10)];

    let plan: ParsedPlan | undefined;

    const adaptivePickRange = hybridIndexedActivityPool
      ? computeAdaptivePickRange(hybridIndexedActivityPool.length)
      : null;
    const tryHybridPlanDay =
      action === PLAN_DAY_ACTION &&
      typeof OPENAI_API_KEY === "string" &&
      OPENAI_API_KEY.length > 0 &&
      cityProfile != null &&
      planDayHybridAnchor &&
      hybridIndexedActivityPool &&
      adaptivePickRange != null &&
      poolByPlaceId.size > 0;

    if (action === PLAN_DAY_ACTION && !tryHybridPlanDay) {
      const sm = parsePlanDayClockToMinutes(body.time_start!.trim());
      const em = parsePlanDayClockToMinutes(body.time_end!.trim());
      step("journey_hybrid_skipped", {
        reason: "hybrid_prerequisites_not_met",
        has_openai_key: Boolean(OPENAI_API_KEY && OPENAI_API_KEY.length > 0),
        has_city_profile: cityProfile != null,
        has_hybrid_anchor: planDayHybridAnchor != null,
        hybrid_pool_len: hybridIndexedActivityPool?.length ?? 0,
        wishlist_min_picks: WISHLIST_MIN_PICKS,
        wishlist_min_picks_floor: WISHLIST_MIN_PICKS_FLOOR,
        adaptive_pick_range: adaptivePickRange,
        ranked_place_ids: poolByPlaceId.size,
        time_window_ok: sm != null && em != null && em > sm,
      });
    }

    if (tryHybridPlanDay) {
      const indexedPool = hybridIndexedActivityPool!;
      const hybridAnchor = planDayHybridAnchor!;
      const hybridCityProfileId = cityProfile!.id;
      const { minPicks, maxPicks } = adaptivePickRange!;

      const dayKey = body.date!.trim().slice(0, 10);
      const dayTz = displayTz ?? tripStoredTz;
      const dayOfWeek = dayTz
        ? (() => {
          const wd = DateTime.fromISO(dayKey, { zone: dayTz }).weekday;
          return wd === 7 ? 0 : wd;
        })()
        : new Date(`${dayKey}T12:00:00Z`).getUTCDay();

      const startM = parsePlanDayClockToMinutes(body.time_start!.trim());
      const endM = parsePlanDayClockToMinutes(body.time_end!.trim());
      if (startM != null && endM != null && endM > startM) {
        try {
          const hybridStartedAt = Date.now();
          step("journey_hybrid_llm_begin", {
            day_key: dayKey,
            pool_rows: indexedPool.length,
            ranked_place_ids: poolByPlaceId.size,
          });
          const hybridPlan = await executePlanDayHybrid({
            admin,
            openAiApiKey: OPENAI_API_KEY,
            openAiModel: openaiItineraryModel(),
            indexedPool: indexedPool,
            cityProfileId: hybridCityProfileId,
            ttdpAnchor: hybridAnchor,
            dayDate: dayKey,
            dayStartMin: startM,
            dayEndMin: endM,
            maxStops: body.stop_count_max!,
            explorationScope: normalizeExplorationScope(body.exploration_scope),
            excludePlaces: excludePlaceNames,
            includeMeals: body.include_meals !== false,
            traveler: {
              travel_style: body.travel_style,
              pace: body.pace,
              interest_ids: Array.isArray(body.interests) ? body.interests : [],
            },
            cityLabel: planDayHybridCityLabel || body.destination!.trim(),
            userPace: body.pace,
            tripDepth:
              typeof (body as { trip_depth?: string }).trip_depth === "string"
                ? (body as { trip_depth?: string }).trip_depth
                : null,
            dayOfWeek,
            destinationLabelForQuery:
              planDayHybridDestQuery || body.destination!.trim(),
            poolByPlaceId,
            adaptiveMinPicks: minPicks,
            adaptiveMaxPicks: maxPicks,
          });

          const val = validateProposedPlanHard(
            hybridPlan as ParsedPlan,
            {
              allowedDayDates,
              poolByPlaceId,
              replaceRequiredSorted,
            },
            audit.trace_id,
          );

          if (val.ok) {
            plan = hybridPlan as ParsedPlan;
            step("journey_hybrid_llm_ok", {
              ms: Date.now() - hybridStartedAt,
              proposed_activity_count: (hybridPlan as ParsedPlan).activities.length,
            });
          } else {
            step(
              "journey_hybrid_validation_failed",
              {
                issues: val.issues.slice(0, 20),
                issue_count: val.issues.length,
              },
              "warn",
            );
          }
        } catch (e) {
          step(
            "journey_hybrid_llm_exception",
            { message: e instanceof Error ? e.message : String(e) },
            "error",
          );
        }
      } else {
        step("journey_hybrid_skipped", {
          reason: "invalid_time_window",
          start_minutes: startM,
          end_minutes: endM,
        });
      }
    }

    if (!plan) {
      step(
        "journey_plan_unsatisfied",
        {
          action,
          try_hybrid_eligible: tryHybridPlanDay,
          note: "no_plan_after_generation_gate",
        },
        "warn",
      );
      return respond(
        {
          error: "plan_generation_failed",
          detail:
            "Could not generate a plan. Try adjusting parameters or expanding the exploration scope.",
        },
        422,
      );
    }

    step("journey_quota_claim_begin", {
      feature: aiFeature,
      monthly_limit: monthlyLimit,
    });
    const { data: claimRows, error: claimErr } = await admin.rpc(
      "claim_ai_usage",
      {
        p_user_id: user.id,
        p_feature: aiFeature,
        p_monthly_limit: monthlyLimit,
      },
    );

    if (claimErr) {
      step("journey_quota_claim_rpc_failed", { message: claimErr.message }, "error");
      return respond(
        {
          error: "quota_check_failed",
          detail: claimErr.message,
        },
        500,
      );
    }

    const claimRow = Array.isArray(claimRows) ? claimRows[0] : claimRows;
    const claimOk = claimRow &&
      typeof claimRow === "object" &&
      "ok" in claimRow &&
      (claimRow as { ok: boolean }).ok;
    if (!claimOk) {
      const claimReason = (claimRow as { reason?: string })?.reason ?? "limit_exceeded";
      // Wave 4.4b: distinguish the daily safety cap from the free
      // monthly cap. The client maps `daily_safety_cap_reached` to a
      // "Try again tomorrow" message, NOT the upgrade paywall — we
      // don't want a Pro user who hit their own anti-abuse cap to
      // see an upsell. The `error` field stays `free_limit_reached`
      // for back-compat with older clients that branch on it; new
      // clients should branch on `reason` instead.
      const isDailySafetyCap = claimReason === "daily_safety_cap_reached";
      step(
        "journey_quota_blocked",
        {
          feature: aiFeature,
          reason: claimReason,
          tier: isDailySafetyCap ? "daily_safety_cap" : "monthly_free",
        },
        "warn",
      );
      return respond(
        {
          error: isDailySafetyCap ? "daily_safety_cap_reached" : "free_limit_reached",
          feature: aiFeature,
          reason: claimReason,
        },
        429,
      );
    }

    step("journey_quota_claim_ok", { feature: aiFeature });

    const dayByDate = new Map<string, DayRow>();
    for (const d of days) dayByDate.set(d.date.slice(0, 10), d);

    const routeScopeForValidation = normalizeExplorationScope(body.exploration_scope);

    const ops: Record<string, unknown>[] = [];

    const effectiveReplaceDates = new Set(
      (plan.replace_ai_days ?? []).map((x) => x.slice(0, 10)),
    );
    for (const p of plan.activities) {
      const dd = p.day_date?.slice(0, 10);
      if (dd) effectiveReplaceDates.add(dd);
    }

    if (effectiveReplaceDates.size) {
      for (const a of activities) {
        if (a.source !== "ai_suggestion") continue;
        const day = days.find((d) => d.id === a.day_id);
        const dk = day?.date.slice(0, 10);
        if (dk && effectiveReplaceDates.has(dk)) {
          ops.push({ action: "delete", id: a.id });
        }
      }
    }

    type Built = {
      day_id: string;
      name: string;
      description: string;
      category: string;
      starts_at: string | null;
      duration_minutes: number | null;
      lat: number | null;
      lng: number | null;
      address: string | null;
      place_id: string | null;
      place_search_query: string | null;
      estimated_cost: number | null;
      currency: string | null;
      rating: number | null;
      price_level: number | null;
      sort_order: number;
      meal_anchor: boolean;
      hero_image_url: string | null;
      /** Preview-only: gallery JSON from pool (stripped before apply). */
      images?: unknown | null;
      /** Preview-only (also on insert row JSON). */
      phase_label: string | null;
      moment_line: string | null;
      tips: string[] | undefined;
      alternatives: ActivityAlternative[] | undefined;
      nearby_meals: NearbyMealSuggestion[] | undefined;
    };

    const builtRows: Built[] = [];
    let sortCursor = 0;

    async function resolveActivity(p: ProposedActivity): Promise<Built | null> {
      const dd = p.day_date?.slice(0, 10);
      if (!dd || !dayByDate.has(dd)) return null;

      const matchedDestRow = destinationForDay(dd, enrichedDestinations);
      const destLabel = matchedDestRow?.label?.trim() ||
        String(trip.destination ?? "").trim();

      const tzForActivity =
        matchedDestRow?.timeZoneId?.trim() ||
        tripStoredTz ||
        displayTz;

      const moment = extractPreviewMomentLine(p);
      let practical = practicalDescriptionAfterMoment(p, moment);
      if (!practical.trim()) {
        if (moment.length === 0) {
          practical = clampDescription(p.description || p.name || "Suggested stop");
          if (!practical.trim()) practical = p.name;
        } else {
          practical = "";
        }
      }

      let desc =
        moment.length > 0 && practical.trim().length > 0
          ? `${moment}\n\n${practical}`
          : moment.length > 0
          ? moment
          : practical;
      desc = clampStoredDescription(desc);
      if (!desc.trim()) desc = p.name;

      const cat = normalizePlanCategory(p.category);

      let lat: number | null = null;
      let lng: number | null = null;
      let address: string | null = null;
      let place_id: string | null = null;

      let ratingSource = typeof p.rating === "number" ? p.rating : null;
      let priceLevelSource = typeof p.price_level === "number" ? p.price_level : null;

      const modelPlaceId = typeof p.place_id === "string" ? p.place_id.trim() : "";
      if (cat !== "transport" && modelPlaceId.length > 0) {
        const { data: pcRow } = await admin
          .from("place_cache")
          .select("latitude,longitude,address,place_id,rating,price_level")
          .eq("place_id", modelPlaceId)
          .maybeSingle();
        if (
          pcRow?.latitude != null &&
          pcRow?.longitude != null &&
          pcRow.place_id
        ) {
          lat = Number(pcRow.latitude);
          lng = Number(pcRow.longitude);
          place_id = pcRow.place_id;
          address = pcRow.address ?? null;
          if (ratingSource == null && typeof pcRow.rating === "number") {
            ratingSource = pcRow.rating;
          }
          if (priceLevelSource == null && typeof pcRow.price_level === "number") {
            priceLevelSource = pcRow.price_level;
          }
        } else {
          const { data: det } = await cachedPlaceDetails(modelPlaceId, admin, {
            skipAiEnrich: true,
          });
          if (det) {
            const geo = det.geometry as Record<string, unknown> | undefined;
            const loc = geo?.location as Record<string, number> | undefined;
            if (typeof loc?.lat === "number" && typeof loc?.lng === "number") {
              lat = loc.lat;
              lng = loc.lng;
              place_id = String(det.place_id ?? modelPlaceId);
              const fa = det.formatted_address;
              address = typeof fa === "string" && fa.length > 0 ? fa : null;
              if (ratingSource == null && typeof det.rating === "number") {
                ratingSource = det.rating as number;
              }
              if (priceLevelSource == null && typeof det.price_level === "number") {
                priceLevelSource = det.price_level as number;
              }
            }
          }
        }
      }

      const primaryQueryRaw = (p.place_query?.trim() ||
        (destLabel.length > 0 ? `${p.name}, ${destLabel}` : p.name)).trim();
      const place_search_query =
        primaryQueryRaw.length > 0
          ? primaryQueryRaw.slice(0, MAX_PLACE_SEARCH_QUERY_LEN)
          : null;

      if (lat == null && primaryQueryRaw.length > 0) {
        const cached = await lookupPlaceCache(admin, p.name, destLabel);
        if (cached) {
          lat = cached.lat;
          lng = cached.lng;
          place_id = cached.place_id;
          address = cached.address || null;
        }
      }

      const rawRating = ratingSource;
      const clampedRating = rawRating != null
        ? Math.round(Math.min(5, Math.max(1, rawRating)) * 10) / 10
        : null;
      const rawPriceLevel = priceLevelSource;
      const clampedPriceLevel = rawPriceLevel != null
        ? Math.min(4, Math.max(0, Math.round(rawPriceLevel)))
        : null;

      const plannedThumb = typeof p.thumbnail_url === "string" ? p.thumbnail_url.trim() : "";
      const galleryFirst = firstImageUrlFromImagesJson(p.images);
      const heroImageUrl =
        (galleryFirst && galleryFirst.slice(0, 2000)) ||
        (plannedThumb.length > 0 ? plannedThumb.slice(0, 2000) : null);

      const phaseLabelRaw =
        typeof p.phase_label === "string" ? p.phase_label.trim().slice(0, MAX_PREVIEW_PHASE_LABEL_LEN) : "";
      const phase_label = phaseLabelRaw.length > 0 ? phaseLabelRaw : null;
      const moment_line = moment.length > 0 ? moment : null;
      const tips = sanitizePreviewTips(p.tips);
      const alternatives = sanitizePreviewAlternatives(p.alternatives);
      const nearby_meals = sanitizePreviewNearbyMeals(p.nearby_meals);

      return {
        day_id: dayByDate.get(dd)!.id,
        name: p.name.slice(0, 500),
        description: desc,
        category: cat,
        starts_at: normalizeActivityStartsAt(dd, p, tzForActivity),
        duration_minutes: p.duration_minutes ?? null,
        lat,
        lng,
        address,
        place_id,
        place_search_query,
        estimated_cost: p.estimated_cost ?? null,
        currency: p.currency?.trim() || null,
        rating: clampedRating,
        price_level: clampedPriceLevel,
        sort_order: 0,
        meal_anchor: p.meal_anchor === true,
        hero_image_url: heroImageUrl,
        images: p.images ?? null,
        phase_label,
        moment_line,
        tips,
        alternatives,
        nearby_meals,
      };
    }

    step("journey_resolve_stops_begin", {
      proposed_activity_count: plan.activities.length,
    });

    for (let i = 0; i < plan.activities.length; i += PLACE_RESOLVE_CONCURRENCY) {
      const batch = plan.activities.slice(i, i + PLACE_RESOLVE_CONCURRENCY);
      const results = await Promise.all(batch.map(resolveActivity));
      for (const r of results) {
        if (r) {
          r.sort_order = sortCursor++;
          builtRows.push(r);
        }
      }
    }

    if (!displayTz) {
      for (const r of builtRows) {
        if (r.lat != null && r.lng != null) {
          const inferred = await fetchTimeZoneIdCached(r.lat, r.lng);
          if (inferred) {
            displayTz = inferred;
            break;
          }
        }
      }
    }
    if (displayTz) {
      for (const d of enrichedDestinations) {
        d.timeZoneId = displayTz;
      }
    }

    const byDay = new Map<string, Built[]>();
    for (const row of builtRows) {
      const list = byDay.get(row.day_id) ?? [];
      list.push(row);
      byDay.set(row.day_id, list);
    }

    for (const [, list] of byDay) {
      list.sort((a, b) => {
        const ta = a.starts_at ? Date.parse(a.starts_at) : 0;
        const tb = b.starts_at ? Date.parse(b.starts_at) : 0;
        if (ta !== tb) return ta - tb;
        return a.sort_order - b.sort_order;
      });

      const dayRow = days.find((d) => d.id === list[0]?.day_id);
      const dd = dayRow?.date.slice(0, 10) ?? "";
      const dest = dd ? destinationForDay(dd, enrichedDestinations) : null;
      const zone = dest?.timeZoneId?.trim() || displayTz;

      const windowStart = body.time_start!.trim();
      const windowEnd = body.time_end!.trim();

      if (zone && list.length > 0) {
        fillMissingPlanDayStartsAt(list, dd, zone, windowStart, windowEnd);
      }

      const routeKm = computeRouteTotalKm(list);
      const maxRouteKm = cityProfile != null
        ? getProfileMaxRouteKm(cityProfile, routeScopeForValidation)
        : (DEFAULT_MAX_ROUTE_KM_BY_SCOPE[routeScopeForValidation] ?? 35);

      if (routeKm > maxRouteKm) {
        step(
          "journey_route_km_over_limit",
          {
            route_km: +routeKm.toFixed(2),
            max_route_km: maxRouteKm,
            exploration_scope: routeScopeForValidation,
          },
          "warn",
        );
      }

      /** Preview connectors use walking minutes (matches client "N min walk" copy). */
      const previewLegTravelMode = "walking";
      const travelMinByIndex: (number | null)[] = new Array(list.length).fill(null);
      await Promise.all(
        list.map(async (_, i) => {
          if (i === 0) return;
          const prev = list[i - 1]!;
          const cur = list[i]!;
          if (prev.lat == null || prev.lng == null || cur.lat == null || cur.lng == null) return;
          travelMinByIndex[i] = await distanceLegMinutesCached(
            { lat: prev.lat, lng: prev.lng },
            { lat: cur.lat, lng: cur.lng },
            previewLegTravelMode,
          );
        }),
      );

      for (let i = 0; i < list.length; i++) {
        list[i].sort_order = i;
        const travelMin = travelMinByIndex[i] ?? null;
        let dirUrl: string | null = null;
        const cur = list[i];
        const mode = "driving";
        const prev = i > 0 ? list[i - 1] : null;
        if (cur.lat != null && cur.lng != null) {
          const fromArg = prev?.lat != null && prev?.lng != null
            ? { lat: prev.lat!, lng: prev.lng!, name: prev.name }
            : null;
          dirUrl = directionsUrl(
            { lat: cur.lat!, lng: cur.lng!, name: cur.name },
            mode,
            fromArg,
            cur.place_id,
          );
        }
        ops.push({
          action: "insert",
          row: {
            day_id: list[i].day_id,
            name: list[i].name,
            description: list[i].description,
            category: list[i].category,
            starts_at: list[i].starts_at,
            duration_minutes: list[i].duration_minutes,
            latitude: list[i].lat,
            longitude: list[i].lng,
            address: list[i].address,
            place_id: list[i].place_id,
            place_search_query: list[i].place_search_query,
            estimated_cost: list[i].estimated_cost,
            currency: list[i].currency,
            rating: list[i].rating,
            price_level: list[i].price_level,
            sort_order: list[i].sort_order,
            travel_from_previous_minutes: travelMin,
            directions_url: dirUrl,
            travel_mode: mode,
            meal_anchor: list[i].meal_anchor,
            hero_image_url: list[i].hero_image_url,
            ...(list[i].images !== undefined && list[i].images !== null
              ? { images: list[i].images }
              : {}),
            ...(list[i].phase_label != null ? { phase_label: list[i].phase_label } : {}),
            ...(list[i].moment_line != null ? { moment_line: list[i].moment_line } : {}),
            ...(list[i].tips && list[i].tips.length > 0 ? { tips: list[i].tips } : {}),
            ...(list[i].alternatives && list[i].alternatives.length > 0
              ? { alternatives: list[i].alternatives }
              : {}),
            ...(list[i].nearby_meals && list[i].nearby_meals.length > 0
              ? { nearby_meals: list[i].nearby_meals }
              : {}),
          },
        });
      }
    }

    step("journey_resolve_stops_done", {
      built_stop_count: builtRows.length,
      skipped_or_unresolved: Math.max(0, plan.activities.length - builtRows.length),
    });

    const activityNames = builtRows.map((b) => b.name).filter((n) => n.trim().length > 0);
    const previewOnly = action === PLAN_DAY_ACTION && Boolean(body.preview_only);

    const insertOpCount = ops.filter((o) =>
      (o as { action?: string }).action === "insert"
    ).length;
    const deleteOpCount = ops.filter((o) =>
      (o as { action?: string }).action === "delete"
    ).length;
    step("journey_plan_ops_ready", {
      total_ops: ops.length,
      insert_ops: insertOpCount,
      delete_ops: deleteOpCount,
      preview_only: previewOnly,
    });

    const storyTitle =
      typeof plan.story_title === "string" && plan.story_title.trim().length > 0
        ? clampStoryTitle(plan.story_title)
        : null;
    const storySubtitle =
      typeof plan.story_subtitle === "string" && plan.story_subtitle.trim().length > 0
        ? clampStorySubtitle(plan.story_subtitle)
        : null;

    const storyArc = sanitizeStoryArc(plan.story_arc);

    const storyPayload: Record<string, unknown> = {
      ...(storyTitle ? { story_title: storyTitle } : {}),
      ...(storySubtitle ? { story_subtitle: storySubtitle } : {}),
      ...(storyArc ? { story_arc: storyArc } : {}),
    };

    if (previewOnly) {
      step("journey_response_preview", {
        activity_name_count: activityNames.length,
      });
      return respond(
        {
          summary: plan.summary,
          ...storyPayload,
          applied_ops: 0,
          preview_only: true,
          itinerary_ops: ops,
          google_routes_enabled: Boolean(GOOGLE_MAPS_API_KEY),
          display_timezone: displayTz,
          usage_feature: aiFeature,
          activity_names: activityNames,
        },
        200,
      );
    }

    step("journey_persist_plan_begin", { op_count: ops.length });
    const { error: rpcErr } = await admin.rpc("apply_itinerary_ops", {
      p_trip_id: tripId,
      p_actor_id: user.id,
      p_payload: { ops },
    });

    if (rpcErr) {
      step("journey_persist_plan_failed", { message: rpcErr.message }, "error");
      return respond(
        { error: "Failed to apply itinerary", detail: rpcErr.message },
        500,
      );
    }

    if (displayTz) {
      const { error: tzErr } = await admin
        .from("trips")
        .update({ display_timezone: displayTz })
        .eq("id", tripId);
      if (tzErr) {
        step("journey_display_timezone_persist_failed", {
          message: tzErr.message,
        }, "error");
      }
    }

    step("journey_persist_plan_ok", { applied_ops: ops.length });
    return respond(
      {
        summary: plan.summary,
        ...storyPayload,
        applied_ops: ops.length,
        google_routes_enabled: Boolean(GOOGLE_MAPS_API_KEY),
        display_timezone: displayTz,
        usage_feature: aiFeature,
        activity_names: activityNames,
      },
      200,
    );
  } catch (e) {
    const msg = errorMessage(e) || "Internal error";
    safeLog("error", FUNCTION_NAME, "handler_exception", {
      trace_id: audit.trace_id,
      user_id: audit.user_id,
      trip_id: audit.trip_id,
      action: audit.action,
      error: msg,
    });
    logItineraryAiStep(
      audit.trace_id,
      "journey_handler_exception",
      { message: msg },
      "error",
    );
    await captureException(e, {
      fn: FUNCTION_NAME,
      reason: "handler_exception",
      fields: {
        trace_id: audit.trace_id,
        user_id: audit.user_id,
        trip_id: audit.trip_id,
        action: audit.action,
      },
    });
    return jsonResponseWithAudit(audit, { error: msg }, 500, CORS_HEADERS);
  }
});

