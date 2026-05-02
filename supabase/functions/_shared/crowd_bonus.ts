/**
 * Crowd-aware scheduling helpers: popular_times → hourly busyness lookup + greedy score bonus.
 * Standalone module so `ttdp_optimizer` does not import `itinerary_quality` (would be circular).
 */

import type { CityPlaceDbRow } from "./city_places_pool.ts";

const DAY_NAMES = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"];

/**
 * Pre-extract busyness scores for a specific day-of-week from the popular_times
 * JSONB into a lightweight lookup. Call this BEFORE solveTTDP, not inside it.
 */
export function extractBusynessForDay(
  pool: CityPlaceDbRow[],
  dayOfWeek: number,
): Map<string, number[]> {
  const lookup = new Map<string, number[]>();
  const dayName = DAY_NAMES[dayOfWeek] ?? "monday";

  for (const place of pool) {
    if (!place.popular_times) continue;
    const dayData = place.popular_times[dayName];
    if (!Array.isArray(dayData)) continue;

    const hourly = new Array<number>(24).fill(0);
    for (const entry of dayData) {
      const hourMatch = entry.time?.match(/(\d+)\s*(AM|PM)/i);
      if (!hourMatch) continue;
      let hour = parseInt(hourMatch[1], 10);
      if (hourMatch[2].toUpperCase() === "PM" && hour !== 12) hour += 12;
      if (hourMatch[2].toUpperCase() === "AM" && hour === 12) hour = 0;
      if (hour >= 0 && hour < 24) {
        hourly[hour] = entry.busyness_score ?? 0;
      }
    }
    lookup.set(place.place_id, hourly);
  }

  return lookup;
}

/**
 * Get a crowd-avoidance bonus for scheduling a place at a given hour.
 * Lower busyness = higher bonus (up to +8 for empty, 0 for avg, -5 for peak).
 */
export function crowdBonus(
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
