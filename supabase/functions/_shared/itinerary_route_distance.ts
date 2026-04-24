/**
 * Post-resolve route length check (Change 6 Part 6) — shared so Vitest can cover it.
 */

import { haversineKm } from "./day_plan_candidate_rank_core.ts";

export type RouteStopCoords = {
  lat: number | null;
  lng: number | null;
};

/** Sums haversine km between consecutive stops that both have coordinates. */
export function computeRouteTotalKm(list: RouteStopCoords[]): number {
  let total = 0;
  for (let i = 1; i < list.length; i++) {
    const prev = list[i - 1]!;
    const cur = list[i]!;
    if (
      prev.lat != null &&
      prev.lng != null &&
      cur.lat != null &&
      cur.lng != null
    ) {
      total += haversineKm(
        { lat: prev.lat, lng: prev.lng },
        { lat: cur.lat, lng: cur.lng },
      );
    }
  }
  return total;
}



