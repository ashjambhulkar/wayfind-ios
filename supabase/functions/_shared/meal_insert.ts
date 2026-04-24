/**
 * Change 9 §3c: deterministic lunch/dinner insertion after TTDP sequence.
 */

import { buildCityPlaceSnapshotFromDbRow } from "./city_place_snapshot.ts";
import { effectiveThumbnailFromParts } from "./city_places_pool.ts";
import type { CityPlaceSnapshot } from "../../../types/cityPlaceSnapshot.ts";
import { haversineKm } from "./day_plan_candidate_rank_core.ts";
import type { TTDPStop } from "./ttdp_optimizer.ts";

const LUNCH_DURATION_MINUTES = 75;
const DINNER_DURATION_MINUTES = 90;
const LUNCH_BUFFER_AFTER_STOP_MINUTES = 5;

const LUNCH_WINDOW_EARLIEST_MIN = 11 * 60 + 30;
const LUNCH_WINDOW_LATEST_MIN = 14 * 60;
const DINNER_WINDOW_EARLIEST_MIN = 17 * 60;
const DINNER_WINDOW_LATEST_MIN = 20 * 60;

/** Shortest-commute mode among cached `city_travel_times` columns (walk / drive / transit). */
export type MealCommuteMode = "walking" | "driving" | "transit";

/** Rows joined from `city_place_nearby_meals` + `city_places` for restaurants. */
export type NearbyMealRow = {
  place_id: string;
  name: string;
  lat: number;
  lng: number;
  distance_km: number;
  /** Edge estimate from `city_place_nearby_meals` (walking-oriented). */
  walking_minutes_est: number;
  /** Minutes for the shortest among walk / drive / transit when `city_travel_times` has data. */
  commute_minutes: number;
  commute_mode: MealCommuteMode;
  thumbnail_url?: string | null;
  /** Google-style 0–4; used for budget / classic / splurge badges in preview UI. */
  price_level?: number | null;
  rating?: number | null;
  /** Short venue blurb when present on `city_places`. */
  description?: string | null;
  /** Full `city_places` row snapshot. */
  city_place: CityPlaceSnapshot;
};

export type NearbyMealsByActivityPlaceId = Map<string, NearbyMealRow[]>;

function isExcludedFromMeals(
  excludePlaces: ReadonlySet<string>,
  restaurantName: string,
  restaurantPlaceId: string,
): boolean {
  const nameLower = restaurantName.trim().toLowerCase();
  const pid = restaurantPlaceId.trim();
  for (const raw of excludePlaces) {
    const ex = raw.trim();
    if (ex.length === 0) continue;
    if (pid === ex) return true;
    if (nameLower === ex.toLowerCase()) return true;
  }
  return false;
}

function minGapRequiredForLunch(): number {
  return LUNCH_DURATION_MINUTES + LUNCH_BUFFER_AFTER_STOP_MINUTES;
}

function findBestMealNear(
  before: TTDPStop,
  after: TTDPStop,
  nearbyMeals: NearbyMealsByActivityPlaceId,
  exclude: ReadonlySet<string>,
): NearbyMealRow | null {
  const beforeMeals = nearbyMeals.get(before.place_id) ?? [];
  const afterMeals = nearbyMeals.get(after.place_id) ?? [];

  const byPlaceId = new Map<string, NearbyMealRow & { totalDistKm: number }>();

  for (const m of [...beforeMeals, ...afterMeals]) {
    if (isExcludedFromMeals(exclude, m.name, m.place_id)) continue;
    const distToBefore = haversineKm(
      { lat: m.lat, lng: m.lng },
      { lat: before.lat, lng: before.lng },
    );
    const distToAfter = haversineKm(
      { lat: m.lat, lng: m.lng },
      { lat: after.lat, lng: after.lng },
    );
    const totalDistKm = distToBefore + distToAfter;
    const prev = byPlaceId.get(m.place_id);
    if (!prev || totalDistKm < prev.totalDistKm) {
      byPlaceId.set(m.place_id, { ...m, totalDistKm });
    }
  }

  const candidates = [...byPlaceId.values()].sort(
    (a, b) => a.totalDistKm - b.totalDistKm,
  );
  return candidates[0] ?? null;
}

/**
 * After a TTDP sequence, insert lunch (11:30–14:00 gap between neighbors) and/or dinner
 * (after last stop when the day runs past 17:00), using `city_place_nearby_meals`-shaped lookups.
 *
 * - Lunch: among consecutive pairs whose gap midpoint falls in the lunch window, pick the **largest**
 *   gap that can fit lunch (≥ duration + buffer); choose the restaurant minimizing haversine sum to both neighbors.
 * - Dinner: if `includeDinner` and `dayEndMin >= 17:00` and last stop ends by 20:00, pick nearest restaurant
 *   to the last stop by `distance_km` among rows for that activity `place_id`.
 * - `excludePlaces`: trimmed strings matched on **`place_id` (exact)** or **`name` (case-insensitive)**.
 */
export function insertMeals(
  sequence: TTDPStop[],
  nearbyMeals: NearbyMealsByActivityPlaceId,
  excludePlaces: ReadonlySet<string> | readonly string[],
  includeLunch: boolean,
  includeDinner: boolean,
  dayEndMin: number,
): TTDPStop[] {
  const exclude = excludePlaces instanceof Set
    ? excludePlaces
    : new Set(excludePlaces);

  const result: TTDPStop[] = [...sequence];

  if (includeLunch && result.length >= 2) {
    let bestGapIdx = -1;
    let bestGapSize = 0;

    for (let i = 0; i < result.length - 1; i++) {
      const gapStart = result[i]!.end_minutes;
      const gapEnd = result[i + 1]!.start_minutes;
      const gapSize = gapEnd - gapStart;
      if (gapSize < minGapRequiredForLunch()) continue;

      const gapMid = (gapStart + gapEnd) / 2;
      if (
        gapMid >= LUNCH_WINDOW_EARLIEST_MIN &&
        gapMid <= LUNCH_WINDOW_LATEST_MIN &&
        gapSize > bestGapSize
      ) {
        bestGapSize = gapSize;
        bestGapIdx = i;
      }
    }

    if (bestGapIdx < 0) {
      let bestForceIdx = -1;
      let bestForceMid = Infinity;
      const idealLunchMid = (LUNCH_WINDOW_EARLIEST_MIN + LUNCH_WINDOW_LATEST_MIN) / 2;

      for (let i = 0; i < result.length - 1; i++) {
        const boundary = result[i]!.end_minutes;
        if (boundary >= LUNCH_WINDOW_EARLIEST_MIN && boundary <= LUNCH_WINDOW_LATEST_MIN) {
          const distFromIdeal = Math.abs(boundary - idealLunchMid);
          if (distFromIdeal < bestForceMid) {
            bestForceMid = distFromIdeal;
            bestForceIdx = i;
          }
        }
      }

      if (bestForceIdx >= 0) {
        const before = result[bestForceIdx]!;
        const meal = findBestMealNear(before, result[bestForceIdx + 1]!, nearbyMeals, exclude);
        if (meal) {
          const lunchStart = before.end_minutes + LUNCH_BUFFER_AFTER_STOP_MINUTES;
          const lunchEnd = lunchStart + LUNCH_DURATION_MINUTES;
          const shift = lunchEnd - result[bestForceIdx + 1]!.start_minutes;
          if (shift > 0) {
            const lastEnd = result[result.length - 1]!.end_minutes + shift;
            if (lastEnd <= dayEndMin) {
              for (let j = bestForceIdx + 1; j < result.length; j++) {
                result[j]!.start_minutes += shift;
                result[j]!.end_minutes += shift;
              }
            } else {
              const overflow = result.length - 1;
              result.splice(overflow, 1);
              for (let j = bestForceIdx + 1; j < result.length; j++) {
                result[j]!.start_minutes += shift;
                result[j]!.end_minutes += shift;
              }
            }
          }
          const lunchStop: TTDPStop = {
            place_id: meal.place_id,
            name: meal.name,
            lat: meal.lat,
            lng: meal.lng,
            category: "restaurant",
            importance: 5,
            duration_minutes: LUNCH_DURATION_MINUTES,
            start_minutes: lunchStart,
            end_minutes: lunchEnd,
          };
          result.splice(bestForceIdx + 1, 0, lunchStop);
          bestGapIdx = bestForceIdx;
        }
      }
    }

    const lunchAlreadyInserted = bestGapIdx >= 0 &&
      result[bestGapIdx + 1]?.category === "restaurant";

    if (bestGapIdx >= 0 && !lunchAlreadyInserted) {
      const before = result[bestGapIdx]!;
      const after = result[bestGapIdx + 1]!;
      const meal = findBestMealNear(before, after, nearbyMeals, exclude);
      if (meal) {
        const lunchStart = before.end_minutes + LUNCH_BUFFER_AFTER_STOP_MINUTES;
        const lunchEnd = lunchStart + LUNCH_DURATION_MINUTES;
        if (lunchEnd <= after.start_minutes) {
          const lunchStop: TTDPStop = {
            place_id: meal.place_id,
            name: meal.name,
            lat: meal.lat,
            lng: meal.lng,
            category: "restaurant",
            importance: 5,
            duration_minutes: LUNCH_DURATION_MINUTES,
            start_minutes: lunchStart,
            end_minutes: lunchEnd,
          };
          result.splice(bestGapIdx + 1, 0, lunchStop);
        }
      }
    }
  }

  if (
    includeDinner &&
    dayEndMin >= DINNER_WINDOW_EARLIEST_MIN &&
    result.length >= 1
  ) {
    const lastActivity = result[result.length - 1]!;
    if (lastActivity.end_minutes <= DINNER_WINDOW_LATEST_MIN) {
      const lastMeals = nearbyMeals.get(lastActivity.place_id) ?? [];
      const bestDinner = lastMeals
        .filter((m) => !isExcludedFromMeals(exclude, m.name, m.place_id))
        .sort((a, b) => a.distance_km - b.distance_km)[0];

      if (bestDinner) {
        const dinnerStart = Math.max(
          lastActivity.end_minutes + LUNCH_BUFFER_AFTER_STOP_MINUTES,
          DINNER_WINDOW_EARLIEST_MIN,
        );
        const dinnerEnd = dinnerStart + DINNER_DURATION_MINUTES;
        if (dinnerEnd <= dayEndMin) {
          result.push({
            place_id: bestDinner.place_id,
            name: bestDinner.name,
            lat: bestDinner.lat,
            lng: bestDinner.lng,
            category: "restaurant",
            importance: 5,
            duration_minutes: DINNER_DURATION_MINUTES,
            start_minutes: dinnerStart,
            end_minutes: dinnerEnd,
          });
        }
      }
    }
  }

  return result;
}

const LOAD_NEARBY_MEALS_ACTIVITY_CHUNK = 80;
const LOAD_NEARBY_MEALS_RESTAURANT_CHUNK = 120;
const MEAL_TRAVEL_TIMES_FROM_CHUNK = 80;

function nonnegativeMinutes(v: number): number {
  return Math.max(0, Math.round(v));
}

/**
 * Pick the shortest commute among walking (merged DB walk + edge estimate), driving, and transit.
 * Tie-break at equal minutes: walking, then transit, then driving.
 */
export function pickShortestMealCommute(opts: {
  rowWalk: number | null;
  rowDrive: number | null;
  rowTransit: number | null;
  edgeWalkEst: number;
}): { minutes: number; mode: MealCommuteMode } {
  const edgeW = nonnegativeMinutes(opts.edgeWalkEst);
  const rowW = opts.rowWalk != null && Number.isFinite(opts.rowWalk)
    ? nonnegativeMinutes(opts.rowWalk)
    : null;
  const walkMinutes = rowW != null ? Math.min(rowW, edgeW) : edgeW;

  const cand: { mode: MealCommuteMode; m: number }[] = [
    { mode: "walking", m: walkMinutes },
  ];
  if (opts.rowDrive != null && Number.isFinite(opts.rowDrive)) {
    cand.push({ mode: "driving", m: nonnegativeMinutes(opts.rowDrive) });
  }
  if (opts.rowTransit != null && Number.isFinite(opts.rowTransit)) {
    cand.push({ mode: "transit", m: nonnegativeMinutes(opts.rowTransit) });
  }

  const rank = (mode: MealCommuteMode) =>
    mode === "walking" ? 0 : mode === "transit" ? 1 : 2;
  cand.sort((a, b) => a.m - b.m || rank(a.mode) - rank(b.mode));
  return { minutes: cand[0]!.m, mode: cand[0]!.mode };
}

type TravelTimesModesRow = {
  from_place_id: string;
  to_place_id: string;
  walking_minutes: number | null;
  transit_minutes: number | null;
  driving_minutes: number | null;
};

function parseNullableMinutes(v: unknown): number | null {
  if (typeof v !== "number" || !Number.isFinite(v)) return null;
  const n = Math.round(v);
  return n >= 0 ? n : null;
}

/** `from|to` → per-mode minutes from `city_travel_times` (activity → restaurant). */
async function loadTravelTimesModesForMealPairs(
  admin: NearbyMealsQueryAdmin,
  cityProfileId: string,
  fromPlaceIds: string[],
  toPlaceIds: string[],
): Promise<Map<string, { w: number | null; d: number | null; t: number | null }>> {
  const out = new Map<string, { w: number | null; d: number | null; t: number | null }>();
  const fromIds = [...new Set(fromPlaceIds.map((s) => s.trim()).filter(Boolean))];
  const toIds = [...new Set(toPlaceIds.map((s) => s.trim()).filter(Boolean))];
  if (fromIds.length === 0 || toIds.length === 0) return out;

  for (let i = 0; i < fromIds.length; i += MEAL_TRAVEL_TIMES_FROM_CHUNK) {
    const chunk = fromIds.slice(i, i + MEAL_TRAVEL_TIMES_FROM_CHUNK);
    const { data, error } = await admin
      .from("city_travel_times")
      .select(
        "from_place_id, to_place_id, walking_minutes, transit_minutes, driving_minutes",
      )
      .eq("city_profile_id", cityProfileId)
      .in("from_place_id", chunk)
      .in("to_place_id", toIds);

    if (error) {
      console.warn("[loadNearbyMeals] city_travel_times batch failed:", error.message);
      continue;
    }
    for (const raw of (data ?? []) as TravelTimesModesRow[]) {
      const from = typeof raw.from_place_id === "string" ? raw.from_place_id.trim() : "";
      const to = typeof raw.to_place_id === "string" ? raw.to_place_id.trim() : "";
      if (!from || !to) continue;
      const w = parseNullableMinutes(raw.walking_minutes);
      const d = parseNullableMinutes(raw.driving_minutes);
      const t = parseNullableMinutes(raw.transit_minutes);
      if (w == null && d == null && t == null) continue;
      out.set(`${from}|${to}`, { w, d, t });
    }
  }
  return out;
}

type NearbyMealsQueryAdmin = {
  from: (table: string) => {
    select: (columns: string) => {
      eq: (
        col: string,
        val: string,
      ) => {
        in: (
          col: string,
          vals: string[],
        ) => Promise<{ data: unknown; error?: { message: string } | null }>;
      };
    };
  };
};

/**
 * Load `city_place_nearby_meals` for each activity `place_id` in `sequence`, joined with `city_places`
 * for restaurant name and coordinates.
 */
export async function loadNearbyMeals(
  admin: NearbyMealsQueryAdmin,
  cityProfileId: string,
  sequence: TTDPStop[],
): Promise<NearbyMealsByActivityPlaceId> {
  const out = new Map<string, NearbyMealRow[]>();
  const activityIds = [
    ...new Set(
      sequence.map((s) => s.place_id.trim()).filter((id) => id.length > 0),
    ),
  ];
  if (activityIds.length === 0) return out;

  type EdgeRow = {
    activity_place_id: string;
    restaurant_place_id: string;
    distance_km: number;
    walking_minutes_est: number;
  };

  const edges: EdgeRow[] = [];
  for (let i = 0; i < activityIds.length; i += LOAD_NEARBY_MEALS_ACTIVITY_CHUNK) {
    const chunk = activityIds.slice(i, i + LOAD_NEARBY_MEALS_ACTIVITY_CHUNK);
    const { data, error } = await admin
      .from("city_place_nearby_meals")
      .select(
        "activity_place_id, restaurant_place_id, distance_km, walking_minutes_est",
      )
      .eq("city_profile_id", cityProfileId)
      .in("activity_place_id", chunk);

    if (error) {
      console.warn("[loadNearbyMeals] edges query failed:", error.message);
      continue;
    }
    for (const row of (data ?? []) as EdgeRow[]) {
      edges.push(row);
    }
  }

  if (edges.length === 0) return out;

  const restIds = [
    ...new Set(
      edges.map((e) => e.restaurant_place_id.trim()).filter(Boolean),
    ),
  ];
  const placeById = new Map<string, CityPlaceSnapshot>();

  for (let i = 0; i < restIds.length; i += LOAD_NEARBY_MEALS_RESTAURANT_CHUNK) {
    const chunk = restIds.slice(i, i + LOAD_NEARBY_MEALS_RESTAURANT_CHUNK);
    const { data, error } = await admin
      .from("city_places")
      .select("*")
      .eq("city_profile_id", cityProfileId)
      .in("place_id", chunk);

    if (error) {
      console.warn("[loadNearbyMeals] city_places query failed:", error.message);
      continue;
    }
    for (const raw of (data ?? []) as Record<string, unknown>[]) {
      const cat = typeof raw.wayfind_category === "string" ? raw.wayfind_category.trim() : "";
      if (cat === "nightlife") continue;
      const snap = buildCityPlaceSnapshotFromDbRow(raw);
      if (!snap) continue;
      const id = snap.place_id.trim();
      if (!id) continue;
      placeById.set(id, snap);
    }
  }

  const activityIdsFromEdges = [
    ...new Set(edges.map((e) => e.activity_place_id.trim()).filter(Boolean)),
  ];
  const travelModesMap = await loadTravelTimesModesForMealPairs(
    admin,
    cityProfileId,
    activityIdsFromEdges,
    restIds,
  );

  for (const e of edges) {
    const snap = placeById.get(e.restaurant_place_id.trim());
    if (!snap) continue;
    const thumb = effectiveThumbnailFromParts(snap.thumbnail_url, snap.images);
    const rawPl = snap.price_level;
    const price_level = typeof rawPl === "number" && Number.isFinite(rawPl)
      ? Math.min(4, Math.max(0, Math.round(rawPl)))
      : null;
    const rawRt = snap.rating;
    const rating = typeof rawRt === "number" && Number.isFinite(rawRt)
      ? Math.min(5, Math.max(0, Math.round(rawRt * 10) / 10))
      : null;
    const shortRaw =
      typeof snap.ai_short_summary === "string" ? snap.ai_short_summary.trim() : "";
    const editorialRaw =
      typeof snap.ai_editorial_summary === "string" ? snap.ai_editorial_summary.trim() : "";
    const descRaw = shortRaw.length > 0 ? shortRaw : editorialRaw;
    const description = descRaw.length > 0 ? descRaw.slice(0, 280) : null;
    const pairKey = `${e.activity_place_id.trim()}|${e.restaurant_place_id.trim()}`;
    const modes = travelModesMap.get(pairKey);
    const commute = pickShortestMealCommute({
      rowWalk: modes?.w ?? null,
      rowDrive: modes?.d ?? null,
      rowTransit: modes?.t ?? null,
      edgeWalkEst: e.walking_minutes_est,
    });
    const meal: NearbyMealRow = {
      place_id: snap.place_id,
      name: snap.name,
      lat: snap.lat,
      lng: snap.lng,
      distance_km: e.distance_km,
      walking_minutes_est: e.walking_minutes_est,
      commute_minutes: commute.minutes,
      commute_mode: commute.mode,
      thumbnail_url: thumb,
      price_level,
      rating,
      description,
      city_place: snap,
    };
    const aid = e.activity_place_id.trim();
    const list = out.get(aid) ?? [];
    list.push(meal);
    out.set(aid, list);
  }

  return out;
}



