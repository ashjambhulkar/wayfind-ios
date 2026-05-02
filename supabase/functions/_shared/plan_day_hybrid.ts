/**
 * Change 9 Part 6: `plan_day` hybrid path — indexed pool wish list + TTDP + meals → plan-shaped JSON
 * consumed by itinerary-ai (same validation / resolve / ops pipeline as full LLM).
 */

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import type { CityPlaceSnapshot } from "../../../types/cityPlaceSnapshot.ts";
import { buildCityPlaceSnapshotFromDbRow } from "./city_place_snapshot.ts";
import {
  effectiveCityPlaceThumbnailUrl,
  effectiveThumbnailFromParts,
  type CityPlaceDbRow,
} from "./city_places_pool.ts";
import type { RankedCandidate } from "./day_plan_candidate_rank_core.ts";
import {
  insertMeals,
  loadNearbyMeals,
  type NearbyMealRow,
  type NearbyMealsByActivityPlaceId,
} from "./meal_insert.ts";
import { makeSyncTravelLookup, preloadTravelCache, type TTDPTravelEndpoint } from "./travel_cache.ts";
import { matchWishListToPool, normalizeWishListUserPace, normalizeWishListTripDepth } from "./wish_list_match.ts";
import { fetchWishListFromOpenAI } from "./wish_list_prompt.ts";
import { solveTTDP, type TTDPCandidate, type TTDPStop } from "./ttdp_optimizer.ts";
import { fetchAndCacheTravelTimes } from "./travel_times_fetch.ts";
import {
  WISHLIST_MAX_PICKS,
  WISHLIST_MAX_POOL_LINES,
  WISHLIST_MIN_PICKS,
} from "./v2b_ai_constants.ts";
import { computeRouteTotalKm } from "./itinerary_route_distance.ts";
import {
  extractBusynessForDay,
  scoreItineraryQuality,
  evaluateItineraryWithLLM,
  type CityRuleRow,
  type RuleContext,
  type ItineraryQualityScore,
  type LLMEvalScore,
} from "./itinerary_quality.ts";

export type ActivityAlternative = {
  name: string;
  place_id: string;
  category: string;
  duration_minutes: number;
  walk_minutes_from_prev?: number | null;
  brief?: string | null;
  thumbnail_url?: string | null;
  /** Client swap UI: first gallery image from `city_place.images` (preferred over `thumbnail_url`). */
  city_place?: CityPlaceSnapshot | null;
  /** Contextual tips for this alternative (same pipeline as primary stop). */
  tips?: string[];
};

export type NearbyMealSuggestion = {
  name: string;
  place_id: string;
  /** Shortest commute minutes among walk / drive / transit (same as legacy `walk_minutes` field). */
  walk_minutes: number;
  /** Which mode achieved {@link walk_minutes} when `city_travel_times` has data; else `walking`. */
  commute_mode?: "walking" | "driving" | "transit" | null;
  distance_km: number;
  thumbnail_url?: string | null;
  price_level?: number | null;
  rating?: number | null;
  description?: string | null;
  city_place?: CityPlaceSnapshot | null;
};

export type HybridPlanActivity = {
  day_date: string;
  name: string;
  description: string;
  phase_label?: string | null;
  moment_line?: string | null;
  category: string;
  local_time?: string | null;
  duration_minutes?: number | null;
  place_query?: string | null;
  place_id?: string | null;
  meal_anchor?: boolean | null;
  /** From `city_places.thumbnail_url` for preview cards / hero. */
  thumbnail_url?: string | null;
  /** From `city_places.images` — client prefers first URL over thumbnail when present. */
  images?: unknown | null;
  tips?: string[];
  alternatives?: ActivityAlternative[];
  nearby_meals?: NearbyMealSuggestion[];
};

export type HybridParsedPlan = {
  summary: string;
  story_title?: string | null;
  story_subtitle?: string | null;
  story_arc?: string[];
  replace_ai_days?: string[];
  activities: HybridPlanActivity[];
  qualityScore?: ItineraryQualityScore;
};

export type ExecutePlanDayHybridArgs = {
  admin: SupabaseClient;
  openAiApiKey: string;
  openAiModel: string;
  indexedPool: CityPlaceDbRow[];
  cityProfileId: string;
  /** TTDP “hotel” / day-start anchor (pool center or stay). */
  ttdpAnchor: { lat: number; lng: number };
  dayDate: string;
  dayStartMin: number;
  dayEndMin: number;
  maxStops: number;
  explorationScope: string;
  excludePlaces: string[];
  includeMeals: boolean;
  traveler: {
    travel_style?: string;
    pace?: string;
    interest_ids?: string[];
  };
  cityLabel: string;
  userPace: string | undefined;
  tripDepth: string | null | undefined;
  dayOfWeek: number;
  destinationLabelForQuery: string;
  poolByPlaceId: Map<string, RankedCandidate>;
  /** When true, runs LLM evaluator (Layer 3) and retry logic. Adds 1-5s latency. Use for testing/QA only. */
  enableLLMEvaluator?: boolean;
  /** Adaptive min picks for sparse areas (defaults to WISHLIST_MIN_PICKS). */
  adaptiveMinPicks?: number;
  /** Adaptive max picks for sparse areas (defaults to WISHLIST_MAX_PICKS). */
  adaptiveMaxPicks?: number;
};

function wallClockMinutesToHHmm(totalMin: number): string {
  const m = ((Math.round(totalMin) % (24 * 60)) + 24 * 60) % (24 * 60);
  const h = Math.floor(m / 60);
  const min = m % 60;
  return `${h}:${min.toString().padStart(2, "0")}`;
}

function phaseLabelFromStartMinutes(totalMin: number): string {
  const m = ((Math.round(totalMin) % (24 * 60)) + 24 * 60) % (24 * 60);
  const h = m / 60;
  if (h < 10) return "Morning";
  if (h < 12) return "Late morning";
  if (h < 14) return "Lunch";
  if (h < 17) return "Afternoon";
  if (h < 20) return "Evening";
  return "Wind-down";
}

/**
 * Stops from `insertMeals` use restaurant `place_id` that is not on the hybrid activity slice,
 * so `poolByPlaceId` / `indexedPool` lookups miss `thumbnail_url` and `images`.
 * Scan `city_place_nearby_meals` rows (already keyed by activity) for this restaurant and reuse
 * the joined `city_places` snapshot (same source as nearby-meals UI).
 */
function mediaFromNearbyMealsForRestaurant(
  map: NearbyMealsByActivityPlaceId,
  restaurantPlaceId: string,
): { thumbnail_url: string | null; images: unknown | null } {
  const target = restaurantPlaceId.trim();
  if (!target) return { thumbnail_url: null, images: null };

  let best: NearbyMealRow | null = null;
  for (const rows of map.values()) {
    for (const m of rows) {
      if (m.place_id.trim() !== target) continue;
      if (!best || m.distance_km < best.distance_km) best = m;
    }
  }
  if (!best) return { thumbnail_url: null, images: null };

  const cp = best.city_place;
  const edgeThumb = typeof best.thumbnail_url === "string" ? best.thumbnail_url.trim() : "";
  const snapThumb =
    cp && typeof cp.thumbnail_url === "string" ? cp.thumbnail_url.trim() : "";
  const chosenThumb =
    edgeThumb.length > 0 ? edgeThumb : snapThumb.length > 0 ? snapThumb : null;
  const thumbnail_url = effectiveThumbnailFromParts(chosenThumb, cp?.images ?? null);
  const images = cp?.images ?? null;
  return { thumbnail_url, images };
}

// ── Alternatives & Tips ─────────────────────────────────────────────────────

/**
 * Pick the 2 best swap alternatives for a given activity from the dropped
 * TTDP candidates. Prefers geographically close stops in the same time block.
 */
function pickAlternatives(
  stop: TTDPStop,
  dropped: TTDPCandidate[],
  getTravelMin: (from: TTDPTravelEndpoint, to: TTDPTravelEndpoint) => number,
  indexedSlice: CityPlaceDbRow[],
  busynessLookup: Map<string, number[]>,
  maxAlternatives = 2,
): ActivityAlternative[] {
  if (dropped.length === 0) return [];

  const thumbByPlaceId = new Map(
    indexedSlice.map((p) => [p.place_id.trim(), effectiveCityPlaceThumbnailUrl(p)]),
  );

  const scored = dropped
    .filter((d) => d.place_id !== stop.place_id)
    .map((d) => {
      const walkMin = getTravelMin(stop, d);
      let score = d.importance * 5 - walkMin;
      if (d.category === stop.category) score += 3;
      return { candidate: d, walkMin, score };
    })
    .sort((a, b) => b.score - a.score);

  return scored.slice(0, maxAlternatives).map((s) => {
    const dbAlt =
      indexedSlice.find((p) => p.place_id.trim() === s.candidate.place_id.trim()) ?? null;
    const altStop: TTDPStop = {
      ...s.candidate,
      start_minutes: stop.start_minutes,
      end_minutes: stop.end_minutes,
    };
    const altTips = buildActivityTips(
      altStop,
      busynessLookup,
      dbAlt?.reviews_tags ?? null,
      s.walkMin,
      dbAlt,
    );
    const tips = altTips.length > 0 ? altTips.slice(0, 5) : undefined;
    const city_snap = dbAlt
      ? buildCityPlaceSnapshotFromDbRow(dbAlt as unknown as Record<string, unknown>)
      : null;
    return {
      name: s.candidate.name,
      place_id: s.candidate.place_id,
      category: s.candidate.category,
      duration_minutes: s.candidate.duration_minutes,
      walk_minutes_from_prev: s.walkMin,
      brief: s.candidate.moment_line ?? null,
      thumbnail_url: thumbByPlaceId.get(s.candidate.place_id.trim()) ?? null,
      ...(city_snap ? { city_place: city_snap } : {}),
      ...(tips ? { tips } : {}),
    };
  });
}

/**
 * Generate contextual tips from busyness, review tags, and travel time.
 * When that yields at most one tip, append `city_places.ai_know_before_you_go` (deduped).
 */
function buildActivityTips(
  stop: TTDPStop,
  busynessLookup: Map<string, number[]>,
  reviewsTags: string[] | undefined | null,
  travelFromPrevMin: number | null,
  dbPlace?: CityPlaceDbRow | null,
): string[] {
  const tips: string[] = [];
  const hour = Math.floor(stop.start_minutes / 60);

  // Crowd level from popular_times
  const hourly = busynessLookup.get(stop.place_id);
  if (hourly) {
    const score = hourly[hour] ?? 50;
    if (score <= 20) tips.push("Usually quiet at this time");
    else if (score <= 40) tips.push("Usually not too busy at this time");
    else if (score >= 75) tips.push("Can get crowded — arrive early if possible");
  }

  // Review tag–based tips (fallback if few tips so far)
  if (tips.length < 3 && reviewsTags) {
    if (reviewsTags.some((t) => /long wait|advance|book|ticket|reservation/i.test(t))) {
      tips.push("Book tickets in advance to skip the line");
    }
    if (reviewsTags.some((t) => /great view|scenic|panoramic/i.test(t))) {
      tips.push("Known for great views");
    }
    if (reviewsTags.some((t) => /free entry|free admission|no charge/i.test(t))) {
      tips.push("Free entry");
    }
  }

  // Travel time from previous stop
  if (travelFromPrevMin != null && travelFromPrevMin > 0) {
    if (travelFromPrevMin <= 5) tips.push("Short walk from previous stop");
    else if (travelFromPrevMin <= 15) tips.push(`About ${travelFromPrevMin} min walk`);
    else tips.push(`${travelFromPrevMin} min travel — consider transit`);
  }

  // Sparse tips: pull full `city_places.ai_know_before_you_go` list (not the generic website line).
  if (tips.length <= 1) {
    const knowBefore = (dbPlace as any)?.ai_know_before_you_go;
    if (Array.isArray(knowBefore)) {
      const seen = new Set(tips.map((x) => x.trim().toLowerCase()));
      for (const raw of knowBefore.slice(0, 12)) {
        if (typeof raw !== "string") continue;
        const t = raw.trim();
        if (t.length === 0 || t.length > 120) continue;
        const k = t.toLowerCase();
        if (seen.has(k)) continue;
        seen.add(k);
        tips.push(t);
      }
    }
  }

  return tips;
}

/**
 * Get nearby meal suggestions for an activity from the preloaded nearby meals map.
 * Returns up to 3 options sorted by shortest commute (walk / drive / transit).
 */
function getMealSuggestionsForActivity(
  activityPlaceId: string,
  nearbyMeals: NearbyMealsByActivityPlaceId,
  excludePlaces: ReadonlySet<string> | readonly string[],
  maxSuggestions = 3,
): NearbyMealSuggestion[] {
  const meals = nearbyMeals.get(activityPlaceId.trim());
  if (!meals || meals.length === 0) return [];

  const exclude = excludePlaces instanceof Set
    ? excludePlaces
    : new Set(excludePlaces.map((s) => s.trim().toLowerCase()));

  return meals
    .filter((m) => !exclude.has(m.place_id.trim()) && !exclude.has(m.name.trim().toLowerCase()))
    .sort((a, b) => a.commute_minutes - b.commute_minutes)
    .slice(0, maxSuggestions)
    .map((m) => ({
      name: m.name,
      place_id: m.place_id,
      walk_minutes: m.commute_minutes,
      commute_mode: m.commute_mode,
      distance_km: m.distance_km,
      thumbnail_url: m.thumbnail_url?.trim() || null,
      price_level: m.price_level ?? null,
      rating: m.rating ?? null,
      description: m.description ?? null,
      city_place: m.city_place,
    }));
}

/**
 * Runs wish list → match → travel preload → TTDP → optional meals → {@link HybridParsedPlan}.
 * Throws on any hard failure so the caller can fall back to full LLM `plan_day`.
 */
export async function executePlanDayHybrid(
  args: ExecutePlanDayHybridArgs,
): Promise<HybridParsedPlan> {
  const effectiveMinPicks = args.adaptiveMinPicks ?? WISHLIST_MIN_PICKS;
  const effectiveMaxPicks = args.adaptiveMaxPicks ?? WISHLIST_MAX_PICKS;
  const poolCap = Math.min(WISHLIST_MAX_POOL_LINES, args.indexedPool.length);
  if (poolCap < effectiveMinPicks) {
    throw new Error(
      `hybrid: indexed pool too small (${poolCap} < ${effectiveMinPicks})`,
    );
  }

  console.log(
    JSON.stringify({
      tag: "plan_day_hybrid_pool",
      poolCount: args.indexedPool.length,
      poolCap,
      adaptiveRange: `${effectiveMinPicks}-${effectiveMaxPicks}`,
    }),
  );

  const slice = args.indexedPool.slice(0, poolCap);

  const wishList = await fetchWishListFromOpenAI({
    apiKey: args.openAiApiKey,
    model: args.openAiModel,
    indexedPool: slice,
    center: args.ttdpAnchor,
    traveler: args.traveler,
    cityLabel: args.cityLabel,
    explorationScope: args.explorationScope,
    excludeNames: [],
    placesPreFilteredFromExcludes: true,
    adaptiveMinPicks: effectiveMinPicks,
    adaptiveMaxPicks: effectiveMaxPicks,
  });

  const candidates = matchWishListToPool(
    wishList.picks,
    slice,
    args.dayOfWeek,
    args.userPace,
    args.tripDepth,
    args.excludePlaces,
    { minResolvedCandidates: effectiveMinPicks },
  );

  const candidatePlaceIds = candidates.map((c) => c.place_id);
  const travelCache = await preloadTravelCache(
    args.admin,
    args.cityProfileId,
    candidatePlaceIds,
  );
  const getTravelMin = makeSyncTravelLookup(travelCache);

  const busynessLookup = extractBusynessForDay(slice, args.dayOfWeek);

  const optimized = solveTTDP(
    candidates,
    args.ttdpAnchor,
    args.dayStartMin,
    args.dayEndMin,
    getTravelMin,
    args.maxStops,
    busynessLookup,
  );

  if (optimized.sequence.length === 0) {
    throw new Error("hybrid: TTDP produced an empty sequence");
  }

  const nearbyMeals = await loadNearbyMeals(
    args.admin,
    args.cityProfileId,
    optimized.sequence,
  );

  const includeLunch = args.includeMeals;
  const includeDinner = args.includeMeals && args.dayEndMin >= 17 * 60;

  const withMeals = insertMeals(
    optimized.sequence,
    nearbyMeals,
    args.excludePlaces,
    includeLunch,
    includeDinner,
    args.dayEndMin,
  );

  const dayDate = args.dayDate.trim().slice(0, 10);
  const activities: HybridPlanActivity[] = [];

  const excludeSet = new Set(args.excludePlaces.map((s) => s.trim().toLowerCase()));

  for (let stopIdx = 0; stopIdx < withMeals.length; stopIdx++) {
    const stop = withMeals[stopIdx]!;
    const poolRow = args.poolByPlaceId.get(stop.place_id.trim());
    const dbPlace = slice.find((p) => p.place_id === stop.place_id);
    const nameForPlan = poolRow?.name?.trim() || stop.name;
    const category = poolRow?.wayfind_category?.trim() || stop.category;
    const moment =
      typeof stop.moment_line === "string" && stop.moment_line.trim().length > 0
        ? stop.moment_line.trim()
        : "";

    const description = moment.length > 0 ? moment : "";

    const travelFromPrev = stopIdx > 0
      ? getTravelMin(withMeals[stopIdx - 1]!, stop)
      : null;

    const tips = buildActivityTips(
      stop,
      busynessLookup,
      dbPlace?.reviews_tags,
      travelFromPrev,
      dbPlace,
    );

    const alternatives = category !== "restaurant"
      ? pickAlternatives(stop, optimized.droppedCandidates, getTravelMin, slice, busynessLookup)
      : [];

    const mealSuggestions = category !== "restaurant"
      ? getMealSuggestionsForActivity(stop.place_id, nearbyMeals, excludeSet)
      : [];

    const thumbFromPool =
      typeof poolRow?.thumbnail_url === "string" ? poolRow.thumbnail_url.trim() : "";
    const thumbFromIndexed = dbPlace ? effectiveCityPlaceThumbnailUrl(dbPlace) : null;
    let thumbnailUrl = thumbFromPool || thumbFromIndexed || null;
    let imagesOut: unknown | null = dbPlace?.images ?? null;

    if (category === "restaurant") {
      const mealMedia = mediaFromNearbyMealsForRestaurant(nearbyMeals, stop.place_id);
      if (!thumbnailUrl && mealMedia.thumbnail_url) {
        thumbnailUrl = mealMedia.thumbnail_url;
      }
      if (imagesOut == null && mealMedia.images != null) {
        imagesOut = mealMedia.images;
      }
    }

    // Build a rich description: prefer moment_line from LLM, fall back to ai_why_go from DB
    const aiWhyGo = Array.isArray((dbPlace as any)?.ai_why_go)
      ? ((dbPlace as any).ai_why_go as string[]).join(". ")
      : "";
    const aiEditorial = typeof (dbPlace as any)?.ai_editorial_summary === "string"
      ? ((dbPlace as any).ai_editorial_summary as string).trim()
      : "";
    const richDescription = moment.length > 0
      ? moment
      : aiWhyGo.length > 0
        ? aiWhyGo.slice(0, 300)
        : aiEditorial.length > 0
          ? aiEditorial.slice(0, 300)
          : "";

    activities.push({
      day_date: dayDate,
      name: nameForPlan,
      description: richDescription,
      phase_label: phaseLabelFromStartMinutes(stop.start_minutes),
      moment_line: moment.length > 0 ? moment : null,
      category,
      local_time: wallClockMinutesToHHmm(stop.start_minutes),
      duration_minutes: stop.duration_minutes,
      place_query: `${nameForPlan}, ${args.destinationLabelForQuery}`.slice(0, 500),
      place_id: stop.place_id,
      meal_anchor: category === "restaurant" ? true : null,
      thumbnail_url: thumbnailUrl,
      images: imagesOut,
      tips,
      alternatives: alternatives.length > 0 ? alternatives : undefined,
      nearby_meals: mealSuggestions.length > 0 ? mealSuggestions : undefined,
    });
  }

  const summary =
    wishList.story_subtitle?.trim() ||
    wishList.story_title?.trim() ||
    `A ${activities.length}-stop day in ${args.cityLabel.trim()}.`;

  // ── Quality scoring (Layer 1 + Layer 2) ──────────────────────────────────
  const generationStartMs = Date.now();
  const cityRules: CityRuleRow[] = []; // populated from DB when city_rules table exists
  const dayDateObj = new Date(dayDate);
  const ruleCtx: RuleContext = {
    pace: normalizeWishListUserPace(args.userPace),
    tripDepth: normalizeWishListTripDepth(args.tripDepth),
    tripDays: 1,
    month: dayDateObj.getMonth() + 1,
  };

  const qualityScore = scoreItineraryQuality(
    withMeals,
    args.ttdpAnchor,
    args.dayStartMin,
    args.dayEndMin,
    getTravelMin,
    cityRules,
    ruleCtx,
  );

  console.log(
    JSON.stringify({
      tag: "itinerary_quality",
      overall: +qualityScore.overall.toFixed(3),
      temporal: +qualityScore.temporal_feasibility.toFixed(2),
      spatial: +qualityScore.spatial_coherence.toFixed(2),
      variety: +qualityScore.variety_and_energy.toFixed(2),
      rules: +qualityScore.city_rules_compliance.toFixed(2),
      practical: +qualityScore.practical_completeness.toFixed(2),
      issues: qualityScore.issues,
      shadowRules: qualityScore.city_rules_violations.filter((v) => v.penalty === 0),
    }),
  );

  // ── Layer 3: LLM Evaluator (behind flag) ────────────────────────────────
  let llmEvalResult: LLMEvalScore | null = null;
  let wasRetried = false;
  let retryReason: string | null = null;
  let retryCount = 0;

  if (args.enableLLMEvaluator && qualityScore.overall >= 0.5 && qualityScore.overall < 0.75) {
    console.log(JSON.stringify({
      tag: "llm_eval_triggered",
      algoScore: +qualityScore.overall.toFixed(3),
    }));

    llmEvalResult = await evaluateItineraryWithLLM(
      withMeals,
      args.cityLabel,
      ruleCtx.month,
      args.dayOfWeek,
      args.traveler.travel_style,
      args.userPace,
      args.traveler.interest_ids,
      args.openAiApiKey,
      args.openAiModel,
    );

    if (llmEvalResult) {
      console.log(JSON.stringify({ tag: "llm_eval_result", ...llmEvalResult }));

      const minScore = Math.min(
        llmEvalResult.flow,
        llmEvalResult.local_feel,
        llmEvalResult.preference_fit,
        llmEvalResult.surprise,
      );

      if (minScore < 3 && llmEvalResult.suggestion) {
        console.log(JSON.stringify({
          tag: "llm_eval_retry",
          suggestion: llmEvalResult.suggestion,
        }));

        try {
          const retryWishList = await fetchWishListFromOpenAI({
            apiKey: args.openAiApiKey,
            model: args.openAiModel,
            indexedPool: slice,
            center: args.ttdpAnchor,
            traveler: args.traveler,
            cityLabel: args.cityLabel,
            explorationScope: args.explorationScope +
              `\n\nIMPORTANT ADJUSTMENT: ${llmEvalResult.suggestion}`,
            excludeNames: [],
            placesPreFilteredFromExcludes: true,
            adaptiveMinPicks: effectiveMinPicks,
            adaptiveMaxPicks: effectiveMaxPicks,
          });

          const retryCandidates = matchWishListToPool(
            retryWishList.picks,
            slice,
            args.dayOfWeek,
            args.userPace,
            args.tripDepth,
            args.excludePlaces,
            { minResolvedCandidates: effectiveMinPicks },
          );

          const retryOptimized = solveTTDP(
            retryCandidates,
            args.ttdpAnchor,
            args.dayStartMin,
            args.dayEndMin,
            getTravelMin,
            args.maxStops,
            busynessLookup,
          );

          if (retryOptimized.sequence.length > 0) {
            const retryWithMeals = insertMeals(
              retryOptimized.sequence,
              nearbyMeals,
              args.excludePlaces,
              includeLunch,
              includeDinner,
              args.dayEndMin,
            );

            const retryQuality = scoreItineraryQuality(
              retryWithMeals,
              args.ttdpAnchor,
              args.dayStartMin,
              args.dayEndMin,
              getTravelMin,
              cityRules,
              ruleCtx,
            );

            if (retryQuality.overall > qualityScore.overall) {
              console.log(JSON.stringify({
                tag: "llm_eval_retry_improved",
                before: +qualityScore.overall.toFixed(3),
                after: +retryQuality.overall.toFixed(3),
              }));

              // Rebuild activities from the improved sequence
              activities.length = 0;
              for (const stop of retryWithMeals) {
                const poolRow = args.poolByPlaceId.get(stop.place_id.trim());
                const dbPlace = slice.find((p) => p.place_id === stop.place_id);
                const nameForPlan = poolRow?.name?.trim() || stop.name;
                const cat = poolRow?.wayfind_category?.trim() || stop.category;
                const moment =
                  typeof stop.moment_line === "string" && stop.moment_line.trim().length > 0
                    ? stop.moment_line.trim()
                    : "";
                const practical =
                  `Allow about ${stop.duration_minutes} minutes here.${cat === "restaurant" ? " Reservations recommended when popular." : ""}`;
                const desc = moment.length > 0 ? `${moment}\n\n${practical}` : practical;

                const thumbFromPool =
                  typeof poolRow?.thumbnail_url === "string" ? poolRow.thumbnail_url.trim() : "";
                const thumbFromIndexed = dbPlace ? effectiveCityPlaceThumbnailUrl(dbPlace) : null;
                let thumbnailUrl = thumbFromPool || thumbFromIndexed || null;
                let imagesOutRetry: unknown | null = dbPlace?.images ?? null;
                if (cat === "restaurant") {
                  const mealMedia = mediaFromNearbyMealsForRestaurant(nearbyMeals, stop.place_id);
                  if (!thumbnailUrl && mealMedia.thumbnail_url) {
                    thumbnailUrl = mealMedia.thumbnail_url;
                  }
                  if (imagesOutRetry == null && mealMedia.images != null) {
                    imagesOutRetry = mealMedia.images;
                  }
                }

                activities.push({
                  day_date: dayDate,
                  name: nameForPlan,
                  description: desc,
                  phase_label: phaseLabelFromStartMinutes(stop.start_minutes),
                  moment_line: moment.length > 0 ? moment : null,
                  category: cat,
                  local_time: wallClockMinutesToHHmm(stop.start_minutes),
                  duration_minutes: stop.duration_minutes,
                  place_query: `${nameForPlan}, ${args.destinationLabelForQuery}`.slice(0, 500),
                  place_id: stop.place_id,
                  meal_anchor: cat === "restaurant" ? true : null,
                  thumbnail_url: thumbnailUrl,
                  images: imagesOutRetry,
                });
              }

              // Use the improved scores for logging
              Object.assign(qualityScore, retryQuality);
              wasRetried = true;
              retryReason = "llm_suggestion";
              retryCount = 1;
            } else {
              console.log(JSON.stringify({
                tag: "llm_eval_retry_no_improvement",
                before: +qualityScore.overall.toFixed(3),
                after: +retryQuality.overall.toFixed(3),
              }));
            }
          }
        } catch (retryErr) {
          console.warn("[llm_eval] retry failed, shipping original:", retryErr);
        }
      }
    }
  }

  // ── Itinerary logging (fire-and-forget) ─────────────────────────────────
  const routeKm = computeRouteTotalKm(
    withMeals.map((s) => ({ lat: s.lat, lng: s.lng })),
  );
  const generationTimeMs = Date.now() - generationStartMs;

  args.admin
    .from("itinerary_logs")
    .insert({
      city_profile_id: args.cityProfileId,
      user_pace: args.userPace ?? null,
      user_trip_depth: args.tripDepth ?? null,
      user_travel_style: args.traveler.travel_style ?? null,
      user_interests: args.traveler.interest_ids ?? null,
      day_date: dayDate,
      wishlist_prompt_hash: null,
      wishlist_response: wishList,
      final_itinerary: activities,
      stop_count: activities.length,
      total_route_km: +routeKm.toFixed(2),
      algo_score: +qualityScore.overall.toFixed(4),
      temporal_feasibility: +qualityScore.temporal_feasibility.toFixed(4),
      spatial_coherence: +qualityScore.spatial_coherence.toFixed(4),
      variety_and_energy: +qualityScore.variety_and_energy.toFixed(4),
      city_rules_compliance: +qualityScore.city_rules_compliance.toFixed(4),
      practical_completeness: +qualityScore.practical_completeness.toFixed(4),
      city_rules_shadow: qualityScore.city_rules_violations.filter((v) => v.penalty === 0),
      llm_eval_score: llmEvalResult
        ? { flow: llmEvalResult.flow, local_feel: llmEvalResult.local_feel, preference_fit: llmEvalResult.preference_fit, surprise: llmEvalResult.surprise }
        : null,
      llm_eval_suggestion: llmEvalResult?.suggestion ?? null,
      was_retried: wasRetried,
      retry_reason: retryReason,
      retry_count: retryCount,
      generation_time_ms: generationTimeMs,
    })
    .then(({ error }) => {
      if (error) console.warn("[itinerary_logs] insert failed:", error.message);
    })
    .catch((err: unknown) => console.warn("[itinerary_logs] insert error:", err));

  fetchAndCacheTravelTimes(args.admin, args.cityProfileId, withMeals).catch(
    (err) => console.warn("[plan_day_hybrid] fetchAndCacheTravelTimes:", err),
  );

  return {
    summary,
    story_title: wishList.story_title ?? null,
    story_subtitle: wishList.story_subtitle ?? null,
    replace_ai_days: [dayDate],
    activities,
    qualityScore,
  };
}



