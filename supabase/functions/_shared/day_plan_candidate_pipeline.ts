/**
 * Builds day-plan candidate pools: reads `city_places` when a city profile id is available (Change 7),
 * otherwise Places Text Search (New) with multi-query recall (Change 5–6). Does **not** call Place Details.
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  cachedGeocode,
  cachedTextSearchDayPlan,
  type DayPlanTextSearchHit,
} from "./cached_google.ts";
import {
  CITY_PLACES_IN_POOL_STATUSES,
  dbPlaceToCandidateInput,
  scopeToMinScopeFilter,
  type CityPlaceDbRow,
} from "./city_places_pool.ts";
import type { CityPlace } from "./city_profile_lookup.ts";
import { buildSearchSpecs } from "./day_plan_search_specs.ts";
import {
  type CandidateCluster,
  type CandidatePlaceInput,
  type RankedCandidate,
  clusterCandidates,
  haversineKm,
  MEAL_TYPE_FRAGMENTS,
  parsePlanDayWindowFlags,
  rankAndShortlistCandidates,
  typesBlob,
} from "./day_plan_candidate_rank_core.ts";
import { filterIndexedPoolForWishList } from "./wish_list_pool_filter.ts";
import { WISHLIST_MIN_PICKS } from "./v2b_ai_constants.ts";

type SupabaseAdmin = ReturnType<typeof createClient>;

/** Change 5 — matches client / `exploration_scope` body field; default `city_wide` when omitted. */
export type ExplorationScope = "walkable" | "city_wide" | "spread_out";

/** Default geographic clustering radius (km) when `clusterRadiusKm` is omitted (matches DB default). */
export const DEFAULT_CLUSTER_RADIUS_KM = 3;

/** Extra Text Search radius (m) around each activity cluster centroid for meal discovery. */
const CLUSTER_MEAL_SEARCH_RADIUS_M = 3000;

/** Meal shortlist cap after cluster-aware meal Text Search expansion (city_wide / spread_out). */
const MEAL_POOL_LIMIT_CLUSTER_EXPANDED = 12;

export function searchRadiusForScope(scope: ExplorationScope): number {
  switch (scope) {
    case "walkable":
      return 4_000;
    case "city_wide":
      return 20_000;
    case "spread_out":
      return 60_000;
    default:
      return 20_000;
  }
}

export const MAX_DIST_CAP_KM: Record<ExplorationScope, number> = {
  walkable: 5,
  city_wide: 25,
  spread_out: 80,
};

const MIN_POOL_CANDIDATES = 4;
const MAX_RADIUS_WIDEN_ATTEMPTS = 2;
const RADIUS_WIDEN_FACTOR = 1.5;

const ACTIVITY_POOL_LIMIT = 20;
const MEAL_POOL_LIMIT = 8;

/**
 * Google place types that indicate a restaurant/bar is an "experience" destination,
 * not just a meal stop. In sparse areas these get promoted into the activity pool.
 */
const EXPERIENCE_RESTAURANT_TYPES = new Set([
  "bar",
  "night_club",
  "spa",
  "lodging",
  "resort_hotel",
  "casino",
  "bowling_alley",
  "amusement_park",
  "water_park",
]);
/**
 * Type substrings that suggest a venue is an experience destination.
 * Matched against the joined types string for broader coverage.
 */
const EXPERIENCE_RESTAURANT_TYPE_FRAGMENTS = [
  "beach",
  "club",
  "lounge",
  "brewery",
  "winery",
  "vineyard",
  "distillery",
  "rooftop",
  "cocktail",
];
/**
 * Returns true if a restaurant-categorized place should be promoted to an activity
 * in sparse areas. Checks types, rating, and review count.
 */
function isExperienceRestaurant(row: CityPlaceDbRow): boolean {
  const types = row.types ?? [];
  const typesBlob = types.join(" ").toLowerCase();
  if (types.some((t) => EXPERIENCE_RESTAURANT_TYPES.has(t))) return true;
  if (EXPERIENCE_RESTAURANT_TYPE_FRAGMENTS.some((f) => typesBlob.includes(f))) return true;
  if ((row.rating ?? 0) >= 4.3 && (row.user_ratings_total ?? 0) >= 500) {
    if (/(rooftop|view|sunset|cliff|terrace|garden|waterfront|beachfront|pool)/i.test(row.name)) {
      return true;
    }
  }
  return false;
}

/** Legacy export — activity + meal shortlist caps sum to this. */
export const TARGET_SHORTLIST = ACTIVITY_POOL_LIMIT + MEAL_POOL_LIMIT;

function hitToInput(h: DayPlanTextSearchHit, listHitCount: number): CandidatePlaceInput {
  return {
    place_id: h.place_id,
    name: h.name,
    types: h.types,
    rating: h.rating,
    user_ratings_total: h.user_ratings_total,
    price_level: h.price_level,
    lat: h.lat,
    lng: h.lng,
    formatted_address: h.formatted_address,
    open_now: h.open_now,
    list_hit_count: listHitCount,
  };
}

function isMealVenueTypes(types: string[]): boolean {
  const blob = typesBlob(types);
  return MEAL_TYPE_FRAGMENTS.some((f) => blob.includes(f));
}

export type FetchPlanDayPoolArgs = {
  /** City / region string for trip context (often same as `citySearchLabel`). */
  destinationLabel: string;
  /** Stay or day-planner anchor for "near {base}" queries — aligns with Planning area center (Change 1). */
  baseLabel: string;
  /**
   * Broad city label for "in {city}" Text Search queries (Change 6).
   * Defaults to `destinationLabel` when omitted.
   */
  citySearchLabel?: string;
  /** When null, geocodes `baseLabel` then `destinationLabel`. */
  center: { lat: number; lng: number } | null;
  interests: string[];
  includeMeals: boolean;
  timeStart: string;
  timeEnd: string;
  scope: ExplorationScope;
  /** Search radius in meters; defaults to scope-based preset when omitted. */
  searchRadiusM?: number;
  /** Max distance from pool center (km); defaults to scope-based cap when omitted. */
  distCapKm?: number;
  /** Geographic clustering radius (km) for `clusterCandidates`; defaults to {@link DEFAULT_CLUSTER_RADIUS_KM}. */
  clusterRadiusKm?: number;
  /**
   * Optional profile id for logging / hybrid downstream; **not** used to filter `city_places`
   * (pool is geographic across profiles).
   */
  cityProfileId?: string | null;
  /** Pre-filtered pool rows for Google fallback recall boost (legacy anchor shape). */
  anchorPlaces?: CityPlace[];
  /** Kept for API compatibility; Place Details enrichment is not used. */
  admin?: SupabaseAdmin;
  /** Place names/IDs already on the trip (other days). Excluded before ranking so ranking slots aren't wasted. */
  excludePlaces?: string[];
};

export type FetchPlanDayPoolResult = {
  activityClusters: CandidateCluster[];
  mealPool: RankedCandidate[];
  /** Flat union of ranked activities + meals for post-generation validation. */
  allCandidates: RankedCandidate[];
  /** Same center as Text Search + dist_km in the prompt (Change 2). */
  searchCenter: { lat: number; lng: number } | null;
  /**
   * When candidates come from `city_places`, ranked activity rows in prompt order for Change 9 hybrid
   * (indexed wish list + TTDP). Omitted on Google Text Search fallback.
   */
  hybridIndexedActivityPool?: CityPlaceDbRow[];
};

async function fetchPlanDayCandidatePoolFromCityPlacesTable(
  args: FetchPlanDayPoolArgs,
  center: { lat: number; lng: number },
  scope: ExplorationScope,
  distCapKm: number,
  clusterRadiusKm: number,
): Promise<FetchPlanDayPoolResult | null> {
  const admin = args.admin;
  if (!admin) return null;

  const scopeFilter = scopeToMinScopeFilter(scope);
  const { data: rows, error } = await admin
    .from("city_places")
    .select(
      "place_id,name,lat,lng,formatted_address,types,wayfind_category,min_scope,tier,source_query_count," +
        "opening_hours,rating,user_ratings_total,price_level,time_spent_min,time_spent_max,thumbnail_url,images," +
        "popular_times,reviews_tags,subtypes,ai_why_go,ai_know_before_you_go,ai_editorial_summary,website",
    )
    .in("status", [...CITY_PLACES_IN_POOL_STATUSES])
    .in("min_scope", scopeFilter)
    .order("tier", { ascending: true })
    .order("source_query_count", { ascending: false });

  if (error) {
    console.warn(
      "[candidate-pipeline] city_places query failed:",
      error.message,
    );
    return null;
  }
  if (!rows?.length) return null;

  let effectiveDistCapKm = distCapKm;
  let distFilteredRows: CityPlaceDbRow[] = [];
  for (let attempt = 0; attempt <= MAX_RADIUS_WIDEN_ATTEMPTS; attempt++) {
    distFilteredRows = (rows as CityPlaceDbRow[]).filter((row) => {
      const dKm = haversineKm(center, { lat: row.lat, lng: row.lng });
      return dKm <= effectiveDistCapKm;
    });
    if (distFilteredRows.length >= MIN_POOL_CANDIDATES) break;
    if (attempt < MAX_RADIUS_WIDEN_ATTEMPTS) {
      const prevCap = effectiveDistCapKm;
      effectiveDistCapKm = Math.round(effectiveDistCapKm * RADIUS_WIDEN_FACTOR * 10) / 10;
      console.log(
        `[candidate-pipeline] sparse city_places pool (${distFilteredRows.length} within ${prevCap}km), widening to ${effectiveDistCapKm}km (attempt ${attempt + 1})`,
      );
    }
  }

  const excludeNames = args.excludePlaces ?? [];
  const filteredRows = excludeNames.length > 0
    ? filterIndexedPoolForWishList(distFilteredRows, excludeNames)
    : distFilteredRows;

  if (filteredRows.length < MIN_POOL_CANDIDATES) {
    return null;
  }

  let activityInputs = filteredRows
    .filter((r) => r.wayfind_category !== "restaurant")
    .map((r) => dbPlaceToCandidateInput(r));

  let mealInputs = filteredRows
    .filter((r) => r.wayfind_category === "restaurant")
    .map((r) => dbPlaceToCandidateInput(r));

  if (activityInputs.length < WISHLIST_MIN_PICKS) {
    const restaurantRows = filteredRows.filter((r) => r.wayfind_category === "restaurant");
    const promoted: CandidatePlaceInput[] = [];
    for (const row of restaurantRows) {
      if (isExperienceRestaurant(row)) {
        promoted.push(dbPlaceToCandidateInput(row));
      }
    }
    if (promoted.length > 0) {
      const promotedIds = new Set(promoted.map((p) => p.place_id.trim()));
      activityInputs = [...activityInputs, ...promoted];
      console.log(
        `[candidate-pipeline] promoted ${promoted.length} experience-restaurants to activities: ${
          promoted.map((p) => p.name).join(", ")
        }`,
      );
      const cleanedMealInputs = mealInputs.filter((m) => !promotedIds.has(m.place_id.trim()));
      mealInputs.length = 0;
      mealInputs.push(...cleanedMealInputs);
    }
  }

  const { lunchWindow, dinnerWindow } = parsePlanDayWindowFlags(
    args.timeStart,
    args.timeEnd,
  );
  const baseRankOpts = {
    interestIds: args.interests,
    includeMeals: false,
    lunchWindow,
    dinnerWindow,
    anchor: center,
    geoNormalizeKm: effectiveDistCapKm,
  };

  const rankedActivities = rankAndShortlistCandidates(activityInputs, {
    ...baseRankOpts,
    limit: ACTIVITY_POOL_LIMIT,
  });

  const rowByPlaceId = new Map(
    filteredRows.map((r) => [r.place_id.trim(), r]),
  );
  const hybridIndexedActivityPool: CityPlaceDbRow[] = [];
  for (const c of rankedActivities) {
    const row = rowByPlaceId.get(String(c.place_id).trim());
    if (row) hybridIndexedActivityPool.push(row);
  }

  const activityClusters = clusterCandidates(
    rankedActivities,
    clusterRadiusKm,
    center,
  );

  let rankedMeals: RankedCandidate[] = [];
  if (args.includeMeals) {
    // Cluster-local meal search: find restaurants near each activity cluster
    // so the model has meal options near wherever the day's activities are.
    if (scope !== "walkable" && args.admin) {
      const mealSeen = new Set(mealInputs.map((m) => m.place_id.trim()).filter(Boolean));
      for (const cluster of activityClusters) {
        const { data: clusterMealRows } = await args.admin
          .from("city_places")
          .select(
            "place_id,name,lat,lng,formatted_address,types,wayfind_category,min_scope,tier,source_query_count,thumbnail_url,images",
          )
          .eq("wayfind_category", "restaurant")
          .in("status", [...CITY_PLACES_IN_POOL_STATUSES]);
        for (const row of (clusterMealRows ?? []) as CityPlaceDbRow[]) {
          if (mealSeen.has(row.place_id)) continue;
          const dFromCluster = haversineKm(cluster.centroid, { lat: row.lat, lng: row.lng });
          if (dFromCluster <= 3) {
            mealSeen.add(row.place_id);
            mealInputs.push(dbPlaceToCandidateInput(row));
          }
        }
      }
    }
    const mealLimit = scope !== "walkable"
      ? MEAL_POOL_LIMIT_CLUSTER_EXPANDED
      : MEAL_POOL_LIMIT;
    rankedMeals = rankAndShortlistCandidates(mealInputs, {
      ...baseRankOpts,
      includeMeals: true,
      limit: mealLimit,
    });
  }

  const allCandidates: RankedCandidate[] = [...rankedActivities, ...rankedMeals];

  return {
    activityClusters,
    mealPool: rankedMeals,
    allCandidates,
    searchCenter: center,
    hybridIndexedActivityPool,
  };
}

async function fetchPlanDayCandidatePoolFromGoogle(
  args: FetchPlanDayPoolArgs,
  center: { lat: number; lng: number },
  scope: ExplorationScope,
  initialRadiusM: number,
  distCapKm: number,
  clusterRadiusKm: number,
  specs: ReturnType<typeof buildSearchSpecs>,
): Promise<FetchPlanDayPoolResult> {
  let radiusM = initialRadiusM;

  let activityInputs: CandidatePlaceInput[] = [];
  let mealInputs: CandidatePlaceInput[] = [];

  for (let attempt = 0; attempt <= MAX_RADIUS_WIDEN_ATTEMPTS; attempt++) {
    const acc = new Map<string, { hit: DayPlanTextSearchHit; count: number }>();

    for (const spec of specs) {
      const { hits } = await cachedTextSearchDayPlan(
        spec.textQuery,
        center,
        radiusM,
        spec.includedType,
      );
      for (const h of hits) {
        const id = h.place_id.trim();
        if (!id) continue;
        const cur = acc.get(id);
        if (cur) cur.count += 1;
        else acc.set(id, { hit: h, count: 1 });
      }
    }

    for (const anchor of args.anchorPlaces ?? []) {
      const id = anchor.place_id.trim();
      if (!id) continue;
      const existing = acc.get(id);
      if (existing) {
        existing.count += 2;
        continue;
      }
      const hit: DayPlanTextSearchHit = {
        place_id: anchor.place_id,
        name: anchor.name,
        formatted_address: anchor.formatted_address ?? "",
        lat: anchor.lat,
        lng: anchor.lng,
        types: anchor.types ?? [],
        rating: null,
        user_ratings_total: null,
        price_level: null,
        open_now: null,
      };
      acc.set(id, { hit, count: 3 });
    }

    const allInputs: CandidatePlaceInput[] = [];
    for (const { hit, count } of acc.values()) {
      allInputs.push(hitToInput(hit, count));
    }

    const filtered = allInputs.filter((h) => {
      const dKm = haversineKm(center, { lat: h.lat, lng: h.lng });
      return dKm <= distCapKm;
    });

    activityInputs = filtered.filter((h) => !isMealVenueTypes(h.types));
    mealInputs = filtered.filter((h) => isMealVenueTypes(h.types));

    const totalUsable = activityInputs.length + mealInputs.length;
    if (totalUsable >= MIN_POOL_CANDIDATES || attempt >= MAX_RADIUS_WIDEN_ATTEMPTS) {
      break;
    }
    radiusM = Math.round(radiusM * RADIUS_WIDEN_FACTOR);
    console.log(
      `[candidate-pipeline] sparse pool (${totalUsable} usable under ${distCapKm}km), widening radius to ${radiusM}m (attempt ${attempt + 1})`,
    );
  }

  const { lunchWindow, dinnerWindow } = parsePlanDayWindowFlags(
    args.timeStart,
    args.timeEnd,
  );
  const baseRankOpts = {
    interestIds: args.interests,
    includeMeals: false,
    lunchWindow,
    dinnerWindow,
    anchor: center,
    geoNormalizeKm: distCapKm,
  };

  const rankedActivities = rankAndShortlistCandidates(activityInputs, {
    ...baseRankOpts,
    limit: ACTIVITY_POOL_LIMIT,
  });

  const activityClusters = clusterCandidates(
    rankedActivities,
    clusterRadiusKm,
    center,
  );

  let rankedMeals: RankedCandidate[] = [];

  if (args.includeMeals) {
    if (scope !== "walkable") {
      const mealSeen = new Set(
        mealInputs.map((m) => m.place_id.trim()).filter(Boolean),
      );
      for (const cluster of activityClusters) {
        const { hits } = await cachedTextSearchDayPlan(
          `restaurants near ${cluster.label}`,
          cluster.centroid,
          CLUSTER_MEAL_SEARCH_RADIUS_M,
          "restaurant",
        );
        for (const h of hits) {
          const id = h.place_id.trim();
          if (!id || mealSeen.has(id)) continue;
          mealSeen.add(id);
          mealInputs.push(hitToInput(h, 1));
        }
      }
      rankedMeals = rankAndShortlistCandidates(mealInputs, {
        ...baseRankOpts,
        includeMeals: true,
        limit: MEAL_POOL_LIMIT_CLUSTER_EXPANDED,
      });
    } else {
      rankedMeals = rankAndShortlistCandidates(mealInputs, {
        ...baseRankOpts,
        includeMeals: true,
        limit: MEAL_POOL_LIMIT,
      });
    }
  }

  const allCandidates: RankedCandidate[] = [...rankedActivities, ...rankedMeals];

  return {
    activityClusters,
    mealPool: rankedMeals,
    allCandidates,
    searchCenter: center,
    hybridIndexedActivityPool: undefined,
  };
}

/**
 * Fetches, filters by distance cap, optionally widens radius, splits meal vs activity, ranks separately.
 * Prefer `city_places` when `admin` is set — rows are filtered by scope + distance to `center`
 * (all profiles); otherwise Google Text Search.
 */
export async function fetchPlanDayCandidatePool(
  args: FetchPlanDayPoolArgs,
): Promise<FetchPlanDayPoolResult> {
  const empty: FetchPlanDayPoolResult = {
    activityClusters: [],
    mealPool: [],
    allCandidates: [],
    searchCenter: null,
    hybridIndexedActivityPool: undefined,
  };

  let center = args.center;
  if (!center) {
    const geoLabel = args.baseLabel.trim() || args.destinationLabel.trim();
    const { result } = await cachedGeocode(geoLabel);
    const loc = (result as Record<string, unknown> | null)?.geometry as
      | Record<string, unknown>
      | undefined;
    const locPt = loc?.location as Record<string, number> | undefined;
    const lat = locPt?.lat;
    const lng = locPt?.lng;
    if (typeof lat === "number" && typeof lng === "number" && Number.isFinite(lat) && Number.isFinite(lng)) {
      center = { lat, lng };
    }
  }
  if (!center) return empty;

  const scope = args.scope;
  let radiusM = args.searchRadiusM ?? searchRadiusForScope(scope);
  const distCapKm = args.distCapKm ?? MAX_DIST_CAP_KM[scope] ?? 25;
  const clusterRadiusKm = args.clusterRadiusKm ?? DEFAULT_CLUSTER_RADIUS_KM;
  const citySearch =
    (args.citySearchLabel ?? args.destinationLabel).trim() || args.destinationLabel.trim();

  const specs = buildSearchSpecs(
    citySearch,
    args.baseLabel,
    args.includeMeals,
    scope,
  );

  const fromDb = await fetchPlanDayCandidatePoolFromCityPlacesTable(
    args,
    center,
    scope,
    distCapKm,
    clusterRadiusKm,
  );
  if (fromDb) return fromDb;

  console.warn(
    "[candidate-pipeline] city_places empty or sparse under cap; falling back to Google Text Search",
  );

  return fetchPlanDayCandidatePoolFromGoogle(
    args,
    center,
    scope,
    radiusM,
    distCapKm,
    clusterRadiusKm,
    specs,
  );
}

function roundCoord3(n: number): number {
  return Math.round(n * 1000) / 1000;
}

function distKmFromPoolCenter(
  center: { lat: number; lng: number } | null,
  c: RankedCandidate,
): number | null {
  if (!center) return null;
  if (!Number.isFinite(c.lat) || !Number.isFinite(c.lng)) return null;
  return Math.round(haversineKm(center, { lat: c.lat, lng: c.lng }) * 10) / 10;
}

/**
 * Dual ACTIVITY / MEAL sections for the model (Change 5), with lat/lng/dist_km per row (Change 2).
 */
export function formatCandidatePoolForPrompt(
  activityCandidates: RankedCandidate[],
  mealCandidates: RankedCandidate[],
  destinationLabel: string,
  center: { lat: number; lng: number } | null,
  scope: ExplorationScope | string,
): string {
  if (!activityCandidates.length && !mealCandidates.length) return "";

  // Change 2: only when we have a search center — same as legacy pool (no lat/lng/dist) if geocode failed.
  const geoNote = center
    ? `Pool entries include lat, lng, and dist_km (distance from the pool search center in km) — align with **Planning area center** in USER CHOICES. ` +
      `Use these for geographically coherent sequencing; prefer clusters of nearby stops. ` +
      `Stops far from the center relative to neighbors need a clear reason in the practical description.\n`
    : "";

  const formatLine = (c: RankedCandidate) => {
    const row: Record<string, unknown> = {
      rank: c.rank,
      place_id: c.place_id,
      name: c.name,
    };
    if (center) {
      row.lat = roundCoord3(c.lat);
      row.lng = roundCoord3(c.lng);
      const distKm = distKmFromPoolCenter(center, c);
      if (distKm != null) row.dist_km = distKm;
    }
    row.wayfind_category = c.wayfind_category;
    row.types = c.types.slice(0, 8);
    if (c.rating != null) row.rating = c.rating;
    if (c.user_ratings_total != null) row.rating_count = c.user_ratings_total;
    if (c.price_level != null) row.price_level = c.price_level;
    row.address = (c.formatted_address ?? "").slice(0, 200);
    if (c.open_now != null) row.open_now_hint = c.open_now;
    row.rank_score = Math.round(c.rank_score * 1000) / 1000;
    return JSON.stringify(row);
  };

  const label = destinationLabel.trim();
  const scopeLabel = String(scope).trim() || "city_wide";
  let out = "";

  if (activityCandidates.length > 0) {
    out +=
      `## ACTIVITY CANDIDATES (${label} — ${scopeLabel} scope)\n` +
      `Real Google Places Text Search results for sightseeing and activities. Lower "rank" is stronger.\n` +
      geoNote +
      activityCandidates.map(formatLine).join("\n") +
      "\n";
  }

  if (mealCandidates.length > 0) {
    out +=
      `\n## MEAL CANDIDATES (near base / planning area)\n` +
      `Real Google Places results for restaurants and cafés near your stay or day anchor. Pick meal stops from this section. Lower "rank" is stronger.\n` +
      geoNote +
      mealCandidates.map(formatLine).join("\n") +
      "\n";
  }

  return out;
}

/** Re-exported from a rank-core-only module so Node tests avoid this file's Deno `https://` imports. */
export { formatClusteredPoolForPrompt } from "./day_plan_cluster_prompt_format.ts";

export {
  buildSearchSpecs,
  type DayPlanSearchScope,
  type SearchSpec,
} from "./day_plan_search_specs.ts";



