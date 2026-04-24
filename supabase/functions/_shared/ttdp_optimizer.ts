/**
 * TTDP-style day optimizer (Change 9 Part 3): greedy construction + 2-opt-style swaps,
 * opening-hour windows, sync travel lookup backed by preloaded `city_travel_times` + haversine fallback.
 */

import type { TTDPTravelEndpoint } from "./travel_cache.ts";
import {
  makeSyncTravelLookup,
  preloadTravelCache,
  walkingMinutesHaversineEstimate,
} from "./travel_cache.ts";

export type { TTDPTravelEndpoint };
export { makeSyncTravelLookup, preloadTravelCache, walkingMinutesHaversineEstimate };

/** Synthetic anchor id for hotel / day start position (not a Google place_id). */
export const TTDP_HOTEL_PLACE_ID = "__hotel__";

const MAX_WAIT_BEFORE_OPEN_MINUTES = 30;

/**
 * Crowd-avoidance bonus for scheduling a place at a given hour.
 * Lower busyness = higher bonus (up to +8 for empty, 0 for avg, -5 for peak).
 */
function crowdBonus(
  placeId: string,
  hourOfDay: number,
  busynessLookup: Map<string, number[]>,
): number {
  const hourly = busynessLookup.get(placeId);
  if (!hourly) return 0;
  const hour = Math.max(0, Math.min(23, Math.floor(hourOfDay)));
  const score = hourly[hour]!;
  if (score <= 20) return 8;
  if (score <= 40) return 4;
  if (score <= 60) return 0;
  if (score <= 80) return -3;
  return -5;
}

export type TTDPCandidate = {
  place_id: string;
  name: string;
  lat: number;
  lng: number;
  category: string;
  importance: number;
  duration_minutes: number;
  /** Minutes from midnight; null/undefined = no opening constraint. */
  opens_at_minutes?: number | null;
  /** Minutes from midnight; null/undefined = no closing constraint. */
  closes_at_minutes?: number | null;
  time_of_day_hint?:
    | "morning"
    | "midday"
    | "afternoon"
    | "evening";
  /** From wish list `reason`; stored for itinerary ops (Change 9). */
  moment_line?: string;
};

export type TTDPStop = TTDPCandidate & {
  start_minutes: number;
  end_minutes: number;
};

export type TTDPResult = {
  sequence: TTDPStop[];
  totalTravelMinutes: number;
  totalSatisfaction: number;
  droppedCandidates: TTDPCandidate[];
};

export function hotelEndpoint(
  hotelCoords: { lat: number; lng: number },
): TTDPTravelEndpoint {
  return {
    place_id: TTDP_HOTEL_PLACE_ID,
    lat: hotelCoords.lat,
    lng: hotelCoords.lng,
  };
}

function isClosedAllDayMarker(c: TTDPCandidate): boolean {
  return (
    c.opens_at_minutes === 0 &&
    c.closes_at_minutes === 0
  );
}

function timeOfDayBonus(
  hint: TTDPCandidate["time_of_day_hint"],
  hourOfDay: number,
  category?: string,
): number {
  if (category === "nightlife" && hourOfDay < 16) return -50;

  if (!hint) return 0;
  switch (hint) {
    case "morning":
      return hourOfDay < 12 ? 5 : -5;
    case "midday":
      return hourOfDay >= 10 && hourOfDay < 14 ? 5 : -5;
    case "afternoon":
      return hourOfDay >= 12 && hourOfDay < 17 ? 5 : -5;
    case "evening":
      return hourOfDay >= 16 ? 5 : -20;
    default:
      return 0;
  }
}

/**
 * Simulate visiting `seq` in order from hotel at dayStartMin; returns feasibility and total travel minutes.
 */
export function evaluateSequence(
  seq: TTDPCandidate[],
  hotelCoords: { lat: number; lng: number },
  dayStartMin: number,
  dayEndMin: number,
  getTravelMin: (from: TTDPTravelEndpoint, to: TTDPTravelEndpoint) => number,
): { feasible: boolean; totalTravel: number } {
  let clock = dayStartMin;
  let pos: TTDPTravelEndpoint = hotelEndpoint(hotelCoords);
  let totalTravel = 0;

  for (const stop of seq) {
    if (isClosedAllDayMarker(stop)) {
      return { feasible: false, totalTravel: Number.POSITIVE_INFINITY };
    }
    const travel = getTravelMin(pos, stop);
    totalTravel += travel;
    const arrive = clock + travel;
    const opens = stop.opens_at_minutes;
    const effectiveStart =
      opens != null ? Math.max(arrive, opens) : arrive;

    const closes = stop.closes_at_minutes;
    if (closes != null && effectiveStart + stop.duration_minutes > closes) {
      return { feasible: false, totalTravel: Number.POSITIVE_INFINITY };
    }
    if (effectiveStart + stop.duration_minutes > dayEndMin) {
      return { feasible: false, totalTravel: Number.POSITIVE_INFINITY };
    }

    clock = effectiveStart + stop.duration_minutes;
    pos = stop;
  }

  return { feasible: true, totalTravel };
}

/**
 * Greedy subset construction + pairwise swap improvement (2-opt-style on indices),
 * then final time assignment on the chosen order.
 */
export function solveTTDP(
  candidates: TTDPCandidate[],
  hotelCoords: { lat: number; lng: number },
  dayStartMin: number,
  dayEndMin: number,
  getTravelMin: (from: TTDPTravelEndpoint, to: TTDPTravelEndpoint) => number,
  maxStops: number,
  busynessLookup?: Map<string, number[]>,
): TTDPResult {
  const selected: TTDPCandidate[] = [];
  const remaining = new Set(candidates.map((_, i) => i));
  let currentPos: TTDPTravelEndpoint = hotelEndpoint(hotelCoords);
  let clock = dayStartMin;

  while (remaining.size > 0 && selected.length < maxStops) {
    let bestIdx = -1;
    let bestScore = -Infinity;

    for (const idx of remaining) {
      const cand = candidates[idx]!;
      if (isClosedAllDayMarker(cand)) continue;

      const travelMin = getTravelMin(currentPos, cand);
      const arriveAt = clock + travelMin;

      if (cand.opens_at_minutes != null && arriveAt < cand.opens_at_minutes) {
        const waitMin = cand.opens_at_minutes - arriveAt;
        if (waitMin > MAX_WAIT_BEFORE_OPEN_MINUTES) continue;
      }

      const effectiveArrive = Math.max(
        arriveAt,
        cand.opens_at_minutes ?? arriveAt,
      );

      if (cand.closes_at_minutes != null) {
        if (effectiveArrive + cand.duration_minutes > cand.closes_at_minutes) {
          continue;
        }
      }

      const leaveAt = effectiveArrive + cand.duration_minutes;
      if (leaveAt > dayEndMin) continue;

      let score = cand.importance * 10 - travelMin;
      const hourOfDay = effectiveArrive / 60;
      score += timeOfDayBonus(cand.time_of_day_hint, hourOfDay, cand.category);
      if (busynessLookup) {
        score += crowdBonus(cand.place_id, hourOfDay, busynessLookup);
      }

      if (score > bestScore) {
        bestScore = score;
        bestIdx = idx;
      }
    }

    if (bestIdx < 0) break;

    const chosen = candidates[bestIdx]!;
    const travelMin = getTravelMin(currentPos, chosen);
    const arriveAt = clock + travelMin;
    const effectiveArrive = Math.max(
      arriveAt,
      chosen.opens_at_minutes ?? arriveAt,
    );

    selected.push(chosen);
    remaining.delete(bestIdx);
    clock = effectiveArrive + chosen.duration_minutes;
    currentPos = chosen;
  }

  let improved = true;
  while (improved) {
    improved = false;
    const baseline = evaluateSequence(
      selected,
      hotelCoords,
      dayStartMin,
      dayEndMin,
      getTravelMin,
    ).totalTravel;

    for (let i = 0; i < selected.length - 1; i++) {
      for (let j = i + 1; j < selected.length; j++) {
        const swapped = [...selected];
        const tmp = swapped[i]!;
        swapped[i] = swapped[j]!;
        swapped[j] = tmp;

        const { feasible, totalTravel } = evaluateSequence(
          swapped,
          hotelCoords,
          dayStartMin,
          dayEndMin,
          getTravelMin,
        );

        if (feasible && totalTravel < baseline) {
          selected.splice(0, selected.length, ...swapped);
          improved = true;
          break;
        }
      }
      if (improved) break;
    }
  }

  const sequence: TTDPStop[] = [];
  let assignClock = dayStartMin;
  let assignPos: TTDPTravelEndpoint = hotelEndpoint(hotelCoords);
  let totalTravel = 0;
  let totalSatisfaction = 0;

  for (const stop of selected) {
    const travel = getTravelMin(assignPos, stop);
    totalTravel += travel;
    const arrive = assignClock + travel;
    const effectiveStart = Math.max(
      arrive,
      stop.opens_at_minutes ?? arrive,
    );

    sequence.push({
      ...stop,
      start_minutes: effectiveStart,
      end_minutes: effectiveStart + stop.duration_minutes,
    });

    totalSatisfaction += stop.importance;
    assignClock = effectiveStart + stop.duration_minutes;
    assignPos = stop;
  }

  const selectedRefSet = new Set(selected);
  const droppedCandidates = candidates.filter((c) => !selectedRefSet.has(c));

  return {
    sequence,
    totalTravelMinutes: totalTravel,
    totalSatisfaction,
    droppedCandidates,
  };
}



