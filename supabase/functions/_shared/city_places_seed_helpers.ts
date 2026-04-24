/**
 * Change 7 Part 2: seeding query specs, quality filter, category resolution, per-category tiers.
 * Shared by scripts/seed-city-profiles.ts, Edge auto-seed, and Vitest.
 *
 * Change 9: haversine-based `city_place_nearby_meals` rows after `city_places` seed.
 */

import { haversineKm } from "./day_plan_candidate_rank_core.ts";

/** ~30% of city-wide dist cap (Change 9 §2b). */
const NEARBY_MEALS_RADIUS_FACTOR = 0.3;
const NEARBY_MEALS_WALK_KMH = 5;
const NEARBY_MEALS_DETOUR = 1.3;
const NEARBY_MEALS_MAX_PER_ACTIVITY = 50;
const NEARBY_MEALS_UPSERT_CHUNK = 100;

/** Google Places Text Search (New) maximum results per request. */
export const SEEDING_TEXT_SEARCH_MAX_RESULTS = 20;

export type WayfindSeedCategory =
  | "attraction"
  | "restaurant"
  | "nature"
  | "shopping"
  | "nightlife"
  | "custom";

export type SeedingQuerySpec = {
  query: string;
  includedType?: string;
  targetCategory: WayfindSeedCategory;
};

/**
 * Map Google `types` to a single Wayfind category (Change 7 Part 3 §3b dedup votes).
 * Attraction/museum checked FIRST so venues like "9/11 Memorial" (park + museum)
 * are classified as attraction, not nature.
 */
export function inferCategoryFromTypes(types: string[]): WayfindSeedCategory {
  const s = types.map((t) => t.toLowerCase()).join(" ");
  if (/(museum|tourist_attraction|art_gallery|historical|monument|church|temple|observation_deck|castle)/.test(s)) {
    return "attraction";
  }
  if (/(night_club|casino)/.test(s)) return "nightlife";

  const hasBar = /(bar|pub|cocktail_bar|lounge)/.test(s);
  const hasFood = /(restaurant|cafe|bakery|food)/.test(s);

  if (hasBar && hasFood) return "restaurant";
  if (hasBar) return "nightlife";
  if (hasFood && !/(museum|tourist_attraction)/.test(s)) return "restaurant";

  if (/(park|natural|hiking|garden|zoo|aquarium)/.test(s)) return "nature";
  if (/(shopping|store|market|mall)/.test(s) && !/(museum)/.test(s)) return "shopping";
  return "attraction";
}

export function buildSeedingQueries(searchLabel: string): SeedingQuerySpec[] {
  const city = searchLabel;
  return [
    {
      query: `top tourist attractions in ${city}`,
      targetCategory: "attraction",
    },
    {
      query: `famous landmarks and monuments in ${city}`,
      targetCategory: "attraction",
    },
    { query: `must see places in ${city}`, targetCategory: "attraction" },
    {
      query: `museums in ${city}`,
      includedType: "museum",
      targetCategory: "attraction",
    },
    {
      query: `art galleries in ${city}`,
      includedType: "art_gallery",
      targetCategory: "attraction",
    },
    {
      query: `parks and gardens in ${city}`,
      includedType: "park",
      targetCategory: "nature",
    },
    {
      query: `scenic viewpoints and nature spots in ${city}`,
      targetCategory: "nature",
    },
    {
      query: `shopping markets and malls in ${city}`,
      includedType: "shopping_mall",
      targetCategory: "shopping",
    },
    {
      query: `popular bars and nightlife in ${city}`,
      targetCategory: "nightlife",
    },
    {
      query: `best restaurants in ${city}`,
      includedType: "restaurant",
      targetCategory: "restaurant",
    },
    {
      query: `popular cafes and coffee shops in ${city}`,
      includedType: "cafe",
      targetCategory: "restaurant",
    },
    {
      query: `local food and dining in ${city}`,
      includedType: "restaurant",
      targetCategory: "restaurant",
    },
    {
      query: `restaurants in different neighborhoods of ${city}`,
      includedType: "restaurant",
      targetCategory: "restaurant",
    },
    {
      query: `hidden gem restaurants in ${city}`,
      includedType: "restaurant",
      targetCategory: "restaurant",
    },
    {
      query: `historic sites and heritage in ${city}`,
      targetCategory: "attraction",
    },
    {
      query: `entertainment and theaters in ${city}`,
      targetCategory: "custom",
    },
  ];
}

export const BANNED_TYPE_SUBSTRINGS = [
  "parking",
  "gas_station",
  "atm",
  "car_rental",
  "car_dealer",
  "subway_station",
  "bus_station",
  "transit_station",
  "train_station",
  "light_rail_station",
  "travel_agency",
  "tour_operator",
] as const;

export const GENERIC_NAME_PATTERNS: RegExp[] = [
  /^art\s*gallery$/i,
  /^restaurant$/i,
  /^cafe$/i,
  /^coffee\s*shop$/i,
  /^hotel$/i,
  /^bar$/i,
  /^park$/i,
  /^museum$/i,
  /^bakery$/i,
  /^pharmacy$/i,
  /^store$/i,
];

export const TOUR_PATTERNS: RegExp[] = [
  /\btours?\b/i,
  /\btour\s*(company|operator|agency|guide)\b/i,
];

export function passesQualityFilter(name: string, types: string[]): boolean {
  const trimmed = name.trim();
  if (trimmed.length < 4) return false;

  for (const pat of GENERIC_NAME_PATTERNS) {
    if (pat.test(trimmed)) return false;
  }
  for (const pat of TOUR_PATTERNS) {
    if (pat.test(trimmed)) return false;
  }

  const blob = types.map((t) => t.toLowerCase()).join(" ");
  for (const frag of BANNED_TYPE_SUBSTRINGS) {
    if (blob.includes(frag)) return false;
  }

  const meaningful = types.filter(
    (t) => t !== "point_of_interest" && t !== "establishment",
  );
  if (meaningful.length === 0) return false;

  return true;
}

/** Winning wayfind category from vote counts (ties broken lexicographically). */
export function resolveCategoryFromVotes(
  votes: Map<string, number>,
): WayfindSeedCategory {
  if (votes.size === 0) return "attraction";
  let best: WayfindSeedCategory = "attraction";
  let bestCount = -1;
  for (const [cat, count] of votes) {
    if (
      count > bestCount ||
      (count === bestCount && cat.localeCompare(best) < 0)
    ) {
      best = cat as WayfindSeedCategory;
      bestCount = count;
    }
  }
  return best;
}

export function assignMinScope(
  distFromCenterKm: number,
  walkableCapKm: number,
  cityWideCapKm: number,
): "walkable" | "city_wide" | "spread_out" {
  if (distFromCenterKm <= walkableCapKm) return "walkable";
  if (distFromCenterKm <= cityWideCapKm) return "city_wide";
  return "spread_out";
}

export type PlaceForTierAssignment = {
  wayfind_category: string;
  source_query_count: number;
  tier: 1 | 2 | 3;
};

/**
 * Assign tier 1/2/3 within each wayfind_category by source_query_count (desc),
 * then position in that list (top 5 → tier 1, next 10 → tier 2, rest → tier 3).
 */
export function assignTiersPerCategory<T extends PlaceForTierAssignment>(
  places: Map<string, T>,
): void {
  const byCategory = new Map<string, T[]>();

  for (const p of places.values()) {
    const list = byCategory.get(p.wayfind_category) ?? [];
    list.push(p);
    byCategory.set(p.wayfind_category, list);
  }

  for (const [, list] of byCategory) {
    list.sort((a, b) => b.source_query_count - a.source_query_count);

    for (let i = 0; i < list.length; i++) {
      if (i < 5) list[i]!.tier = 1;
      else if (i < 15) list[i]!.tier = 2;
      else list[i]!.tier = 3;
    }
  }
}

export type NearbyMealsSeedInputPlace = {
  place_id: string;
  lat: number;
  lng: number;
  wayfind_category: string;
};

export type CityPlaceNearbyMealInsertRow = {
  city_profile_id: string;
  activity_place_id: string;
  restaurant_place_id: string;
  distance_km: number;
  walking_minutes_est: number;
};

/**
 * For each non-restaurant place, links up to {@link NEARBY_MEALS_MAX_PER_ACTIVITY} nearest restaurants
 * within `cityWideDistCapKm * NEARBY_MEALS_RADIUS_FACTOR` (haversine). Walking minutes use 5 km/h and 1.3 detour (Change 9).
 */
export function buildCityPlaceNearbyMealRows(
  cityProfileId: string,
  places: NearbyMealsSeedInputPlace[],
  cityWideDistCapKm: number,
): CityPlaceNearbyMealInsertRow[] {
  const radiusKm = Math.max(0.5, cityWideDistCapKm * NEARBY_MEALS_RADIUS_FACTOR);
  const activities = places.filter(
    (p) => p.wayfind_category.trim().toLowerCase() !== "restaurant",
  );
  const restaurants = places.filter(
    (p) => p.wayfind_category.trim().toLowerCase() === "restaurant",
  );
  if (activities.length === 0 || restaurants.length === 0) return [];

  const out: CityPlaceNearbyMealInsertRow[] = [];

  for (const act of activities) {
    const aid = act.place_id.trim();
    if (!aid) continue;

    const scored = restaurants
      .map((r) => {
        const rid = r.place_id.trim();
        if (!rid || rid === aid) return null;
        const dist = haversineKm(
          { lat: act.lat, lng: act.lng },
          { lat: r.lat, lng: r.lng },
        );
        return { r, dist };
      })
      .filter((x): x is { r: NearbyMealsSeedInputPlace; dist: number } =>
        x != null && x.dist <= radiusKm
      )
      .sort((a, b) => a.dist - b.dist)
      .slice(0, NEARBY_MEALS_MAX_PER_ACTIVITY);

    for (const { r, dist } of scored) {
      const rid = r.place_id.trim();
      const walkingMinutesEst = Math.round(
        (dist * NEARBY_MEALS_DETOUR / NEARBY_MEALS_WALK_KMH) * 60,
      );
      out.push({
        city_profile_id: cityProfileId,
        activity_place_id: aid,
        restaurant_place_id: rid,
        distance_km: Math.round(dist * 100) / 100,
        walking_minutes_est: walkingMinutesEst,
      });
    }
  }

  return out;
}

type NearbyMealsUpsertAdmin = {
  from: (table: string) => {
    upsert: (
      rows: CityPlaceNearbyMealInsertRow[],
      options?: { onConflict?: string },
    ) => Promise<{ error?: { message: string } | null }>;
  };
};

/** Batch-upsert edges for `city_place_nearby_meals` (idempotent on unique triple). */
export async function upsertCityPlaceNearbyMealRows(
  admin: NearbyMealsUpsertAdmin,
  rows: CityPlaceNearbyMealInsertRow[],
): Promise<void> {
  for (let i = 0; i < rows.length; i += NEARBY_MEALS_UPSERT_CHUNK) {
    const chunk = rows.slice(i, i + NEARBY_MEALS_UPSERT_CHUNK);
    const { error } = await admin.from("city_place_nearby_meals").upsert(chunk, {
      onConflict: "city_profile_id,activity_place_id,restaurant_place_id",
    });
    if (error) {
      console.warn("[nearby_meals_seed] upsert chunk failed:", error.message);
    }
  }
}



