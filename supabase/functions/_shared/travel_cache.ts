/**
 * Change 9 §3a: pre-load `city_travel_times` for the candidate clique, then synchronous lookup
 * with haversine walking estimate when a pair is missing from cache.
 */

import { haversineKm } from "./day_plan_candidate_rank_core.ts";

const WALKING_SPEED_KMH = 5;
const HAVERSINE_DETOUR_FACTOR = 1.3;

/** Max place_ids per `.in()` filter to stay under PostgREST URL/body limits on batch selects. */
const PRELOAD_FROM_PLACE_ID_CHUNK_SIZE = 80;

export type TTDPTravelEndpoint = {
  place_id: string;
  lat: number;
  lng: number;
};

type TravelTimesRow = {
  from_place_id: string;
  to_place_id: string;
  walking_minutes: number | null;
  driving_minutes: number | null;
};

/** Minimal Supabase client shape for `city_travel_times` batch reads (service role in Edge Functions). */
export type CityTravelTimesAdmin = {
  from: (table: string) => {
    select: (columns: string) => {
      eq: (
        column: string,
        value: string,
      ) => {
        in: (
          column: string,
          values: string[],
        ) => {
          in: (
            column: string,
            values: string[],
          ) => Promise<{ data: unknown; error?: { message: string } | null }>;
        };
      };
    };
  };
};

export function travelCacheKey(fromPlaceId: string, toPlaceId: string): string {
  return `${fromPlaceId}|${toPlaceId}`;
}

/** Walking minutes from straight-line distance (5 km/h, 1.3 detour factor). */
export function walkingMinutesHaversineEstimate(
  from: TTDPTravelEndpoint,
  to: TTDPTravelEndpoint,
): number {
  const distKm = haversineKm(
    { lat: from.lat, lng: from.lng },
    { lat: to.lat, lng: to.lng },
  );
  return Math.round(
    (distKm * HAVERSINE_DETOUR_FACTOR / WALKING_SPEED_KMH) * 60,
  );
}

/**
 * Batch-load travel minutes for all ordered pairs whose endpoints lie in `candidatePlaceIds`
 * (same as `from IN ids AND to IN ids` over the candidate set). Symmetrizes rows so `A|B` and `B|A`
 * both resolve when `driving_minutes` or legacy `walking_minutes` is present (prefers driving).
 *
 * Uses chunked `from_place_id` filters so large candidate sets do not overflow request limits.
 */
export async function preloadTravelCache(
  admin: CityTravelTimesAdmin,
  cityProfileId: string,
  candidatePlaceIds: string[],
): Promise<Map<string, number>> {
  const cache = new Map<string, number>();
  const ids = [
    ...new Set(candidatePlaceIds.map((id) => id.trim()).filter(Boolean)),
  ];
  if (ids.length === 0) return cache;

  for (let i = 0; i < ids.length; i += PRELOAD_FROM_PLACE_ID_CHUNK_SIZE) {
    const fromChunk = ids.slice(i, i + PRELOAD_FROM_PLACE_ID_CHUNK_SIZE);
    const { data, error } = await admin
      .from("city_travel_times")
      .select("from_place_id, to_place_id, walking_minutes, driving_minutes")
      .eq("city_profile_id", cityProfileId)
      .in("from_place_id", fromChunk)
      .in("to_place_id", ids);

    if (error) {
      console.warn(
        "[preloadTravelCache] batch select failed:",
        error.message,
        { cityProfileId, fromChunkSize: fromChunk.length, toSize: ids.length },
      );
      continue;
    }

    const rows = (data ?? []) as TravelTimesRow[];
    for (const row of rows) {
      const minutes =
        row.driving_minutes != null
          ? row.driving_minutes
          : row.walking_minutes;
      if (minutes == null) continue;
      cache.set(
        travelCacheKey(row.from_place_id, row.to_place_id),
        minutes,
      );
      cache.set(
        travelCacheKey(row.to_place_id, row.from_place_id),
        minutes,
      );
    }
  }

  return cache;
}

/**
 * Synchronous travel minutes for the optimizer: cache hit (drive or legacy walk), else haversine walking estimate.
 */
export function makeSyncTravelLookup(
  travelCache: Map<string, number>,
): (from: TTDPTravelEndpoint, to: TTDPTravelEndpoint) => number {
  return (from, to) => {
    const cached = travelCache.get(
      travelCacheKey(from.place_id, to.place_id),
    );
    if (cached != null) return cached;
    return walkingMinutesHaversineEstimate(from, to);
  };
}



