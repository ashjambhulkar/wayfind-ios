/**
 * Change 9 §4b: map wish-list indices to `city_places` rows → `TTDPCandidate[]` with durations + hours + moment_line.
 */

import type { CityPlaceDbRow } from "./city_places_pool.ts";
import { parseOpeningHour } from "./opening_hours_parse.ts";
import type { TTDPCandidate } from "./ttdp_optimizer.ts";
import type { WishListPick } from "./wish_list_prompt.ts";
import { isPlaceExcludedFromWishList } from "./wish_list_pool_filter.ts";
import { WISHLIST_MIN_PICKS } from "./v2b_ai_constants.ts";

export type WishListUserPace = "relaxed" | "moderate" | "efficient";
export type WishListTripDepth = "highlights" | "balanced" | "immersive";

const PACE_MULTIPLIER: Record<WishListUserPace, number> = {
  relaxed: 1.3,
  moderate: 1.0,
  efficient: 0.7,
};

const DEPTH_MULTIPLIER: Record<WishListTripDepth, number> = {
  highlights: 0.8,
  balanced: 1.0,
  immersive: 1.4,
};

const USER_RATINGS_POPULAR_THRESHOLD = 10_000;
const POPULAR_SIZE_MULTIPLIER = 1.2;
const MIN_VISIT_MINUTES = 15;
const MAX_VISIT_MINUTES = 180;

export function normalizeWishListUserPace(
  raw: string | undefined | null,
): WishListUserPace {
  const x = String(raw ?? "moderate").trim().toLowerCase();
  if (x === "relaxed" || x === "efficient") return x;
  return "moderate";
}

export function normalizeWishListTripDepth(
  raw: string | undefined | null,
): WishListTripDepth {
  const x = String(raw ?? "balanced").trim().toLowerCase();
  if (x === "highlights" || x === "immersive") return x;
  return "balanced";
}

/**
 * Base visit duration (minutes) from Wayfind category + Google `types`.
 */
export function getBaseDuration(
  category: string,
  types?: string[] | null,
): number {
  const typeSet = new Set((types ?? []).map((t) => t.trim().toLowerCase()));

  switch (category) {
    case "attraction": {
      if (typeSet.has("museum")) {
        if (typeSet.has("art_gallery")) return 90;
        return 75;
      }
      if (typeSet.has("aquarium")) return 120;
      if (typeSet.has("zoo")) return 150;
      if (typeSet.has("amusement_park")) return 180;
      if (typeSet.has("casino")) return 90;
      if (typeSet.has("tourist_attraction")) return 45;
      if (
        typeSet.has("church") ||
        typeSet.has("synagogue") ||
        typeSet.has("mosque")
      ) {
        return 30;
      }
      return 75;
    }
    case "nature": {
      if (typeSet.has("national_park")) return 120;
      if (typeSet.has("park")) return 60;
      if (typeSet.has("botanical_garden")) return 75;
      if (typeSet.has("beach")) return 90;
      return 60;
    }
    case "shopping": {
      if (typeSet.has("shopping_mall")) return 60;
      return 45;
    }
    case "nightlife": {
      if (typeSet.has("night_club")) return 120;
      if (typeSet.has("bar")) return 75;
      return 90;
    }
    case "restaurant": {
      if (typeSet.has("meal_takeaway") || typeSet.has("meal_delivery")) {
        return 35;
      }
      return 75;
    }
    default:
      return 60;
  }
}

/**
 * Personalized visit length from pace, trip depth, and popularity (Change 9).
 */
export function estimateDuration(
  place: CityPlaceDbRow,
  userPace: WishListUserPace,
  tripDepth: WishListTripDepth,
): number {
  const tsMin = place.time_spent_min;
  const tsMax = place.time_spent_max;
  if (
    tsMin != null && tsMax != null &&
    tsMin > 0 && tsMax > 0 &&
    tsMin <= 480 && tsMax <= 480
  ) {
    const googleBase = tsMin * 0.6 + tsMax * 0.4;
    const dampedPace = 1.0 + (PACE_MULTIPLIER[userPace] - 1.0) * 0.5;
    const dampedDepth = 1.0 + (DEPTH_MULTIPLIER[tripDepth] - 1.0) * 0.3;
    const adjusted = Math.round(googleBase * dampedPace * dampedDepth);
    return Math.max(MIN_VISIT_MINUTES, Math.min(MAX_VISIT_MINUTES, adjusted));
  }

  const base = getBaseDuration(place.wayfind_category, place.types);
  const paceM = PACE_MULTIPLIER[userPace];
  const depthM = DEPTH_MULTIPLIER[tripDepth];
  const ratings = place.user_ratings_total ?? 0;
  const sizeM =
    typeof ratings === "number" &&
    Number.isFinite(ratings) &&
    ratings > USER_RATINGS_POPULAR_THRESHOLD
      ? POPULAR_SIZE_MULTIPLIER
      : 1;
  const rounded = Math.round(base * paceM * depthM * sizeM);
  return Math.max(MIN_VISIT_MINUTES, Math.min(MAX_VISIT_MINUTES, rounded));
}

function openingConstraintMinutes(
  value: number | null,
): number | null | undefined {
  if (value == null) return undefined;
  return value;
}

/**
 * Maps 1-based LLM indices to the same `indexedPool` order used in the wish-list prompt,
 * builds TTDP candidates with `parseOpeningHour` (open + close),
 * and sets `moment_line` from each pick's `reason`.
 * Drops picks that resolve to rows matching `excludeNames` (Layer B).
 * @param options.minResolvedCandidates — default {@link WISHLIST_MIN_PICKS} (hybrid); lower in unit tests that only assert mapping.
 */
export function matchWishListToPool(
  picks: WishListPick[],
  indexedPool: CityPlaceDbRow[],
  dayOfWeek: number,
  userPace: WishListUserPace | string | null | undefined,
  tripDepth: WishListTripDepth | string | null | undefined,
  excludeNames: string[],
  options?: { minResolvedCandidates?: number },
): TTDPCandidate[] {
  const minResolved = options?.minResolvedCandidates ?? WISHLIST_MIN_PICKS;
  const pace = normalizeWishListUserPace(
    userPace == null ? undefined : String(userPace),
  );
  const depth = normalizeWishListTripDepth(
    tripDepth == null ? undefined : String(tripDepth),
  );

  const out: TTDPCandidate[] = [];
  let skippedPickCount = 0;
  for (const pick of picks) {
    const arrayIdx = pick.idx - 1;
    if (arrayIdx < 0 || arrayIdx >= indexedPool.length) continue;
    const dbPlace = indexedPool[arrayIdx]!;
    if (isPlaceExcludedFromWishList(dbPlace, excludeNames)) {
      skippedPickCount += 1;
      continue;
    }
    const oh = dbPlace.opening_hours ?? null;
    const openRaw = parseOpeningHour(oh, dayOfWeek, "open");
    const closeRaw = parseOpeningHour(oh, dayOfWeek, "close");

    out.push({
      place_id: dbPlace.place_id,
      name: dbPlace.name,
      lat: dbPlace.lat,
      lng: dbPlace.lng,
      category: dbPlace.wayfind_category,
      importance: Math.min(10, Math.max(1, Math.round(pick.importance))),
      duration_minutes: estimateDuration(dbPlace, pace, depth),
      opens_at_minutes: openingConstraintMinutes(openRaw),
      closes_at_minutes: openingConstraintMinutes(closeRaw),
      time_of_day_hint: pick.tod,
      moment_line: pick.reason,
    });
  }

  if (skippedPickCount > 0) {
    console.log(
      JSON.stringify({
        tag: "wish_list_match",
        skippedPicksAfterParse: skippedPickCount,
        resolvedCandidates: out.length,
      }),
    );
  }

  if (out.length < minResolved) {
    throw new Error(
      `hybrid: too few wish-list candidates after exclude filter (${out.length} < ${minResolved})`,
    );
  }

  return out;
}



