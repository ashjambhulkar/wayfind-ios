/**
 * Change 9 §3d: post-itinerary travel cache — Mapbox Directions (driving) per leg in parallel,
 * Google Routes fallback for failures or when Mapbox token is absent. Does **not** use haversine;
 * failed pairs are skipped after logging.
 */

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { cachedDirections } from "./cached_google.ts";
import { TTDP_HOTEL_PLACE_ID, type TTDPStop } from "./ttdp_optimizer.ts";

const MAPBOX_DIRECTIONS_BASE =
  "https://api.mapbox.com/directions/v5/mapbox/driving";

type MapboxRouteResponse = {
  routes?: Array<{ duration: number; distance: number }>;
  message?: string;
};

export type TravelTimeInsertRow = {
  city_profile_id: string;
  from_place_id: string;
  to_place_id: string;
  driving_minutes: number;
  /** Cleared when re-caching so legacy walking-only rows are not misread as drive times. */
  walking_minutes: null;
  distance_meters: number | null;
  provider: "mapbox" | "google";
  computed_at: string;
};

function pairKey(fromPlaceId: string, toPlaceId: string): string {
  return `${fromPlaceId.trim()}|${toPlaceId.trim()}`;
}

function isSyntheticPlaceId(placeId: string): boolean {
  const id = placeId.trim();
  return id.length === 0 || id === TTDP_HOTEL_PLACE_ID || id.startsWith("__");
}

function mapboxDrivingUrl(
  from: { lat: number; lng: number },
  to: { lat: number; lng: number },
  accessToken: string,
): string {
  const coords = `${from.lng},${from.lat};${to.lng},${to.lat}`;
  const params = new URLSearchParams({
    access_token: accessToken,
    geometries: "geojson",
  });
  return `${MAPBOX_DIRECTIONS_BASE}/${coords}?${params.toString()}`;
}

async function fetchMapboxDrivingLeg(
  from: { lat: number; lng: number },
  to: { lat: number; lng: number },
  accessToken: string,
): Promise<{ drivingMinutes: number; distanceMeters: number }> {
  const url = mapboxDrivingUrl(from, to, accessToken);
  const res = await fetch(url);
  const body = (await res.json()) as MapboxRouteResponse;
  if (!res.ok) {
    const msg = body.message ?? res.statusText;
    throw new Error(`Mapbox ${res.status}: ${msg}`);
  }
  const route0 = body.routes?.[0];
  if (!route0 || typeof route0.duration !== "number") {
    throw new Error("Mapbox: no route");
  }
  return {
    drivingMinutes: Math.max(1, Math.round(route0.duration / 60)),
    distanceMeters: Math.round(route0.distance),
  };
}

async function loadCachedPairKeys(
  admin: SupabaseClient,
  cityProfileId: string,
  pairKeys: string[],
): Promise<Set<string>> {
  const cached = new Set<string>();
  if (pairKeys.length === 0) return cached;

  const ids = [
    ...new Set(
      pairKeys.flatMap((k) => {
        const [a, b] = k.split("|");
        return [a!, b!].filter(Boolean);
      }),
    ),
  ];
  if (ids.length === 0) return cached;

  const { data, error } = await admin
    .from("city_travel_times")
    .select("from_place_id, to_place_id, driving_minutes")
    .eq("city_profile_id", cityProfileId)
    .in("from_place_id", ids)
    .in("to_place_id", ids);

  if (error) {
    console.warn("[travel-cache] existing rows lookup failed:", error.message);
    return cached;
  }

  const wanted = new Set(pairKeys);
  for (const row of (data ?? []) as {
    from_place_id: string;
    to_place_id: string;
    driving_minutes: number | null;
  }[]) {
    const k = pairKey(row.from_place_id, row.to_place_id);
    if (!wanted.has(k)) continue;
    if (row.driving_minutes != null) cached.add(k);
  }
  return cached;
}

/**
 * Fetches driving legs for consecutive stops, writes `city_travel_times.driving_minutes` with `provider` **mapbox** or **google**.
 * Omits legs involving synthetic place ids. Does **not** fall back to haversine.
 */
export async function fetchAndCacheTravelTimes(
  admin: SupabaseClient,
  cityProfileId: string,
  sequence: TTDPStop[],
): Promise<void> {
  const consecutive: Array<{ from: TTDPStop; to: TTDPStop }> = [];
  for (let i = 1; i < sequence.length; i++) {
    const from = sequence[i - 1]!;
    const to = sequence[i]!;
    if (
      isSyntheticPlaceId(from.place_id) ||
      isSyntheticPlaceId(to.place_id)
    ) {
      continue;
    }
    consecutive.push({ from, to });
  }
  if (consecutive.length === 0) return;

  const pairKeys = consecutive.map((p) =>
    pairKey(p.from.place_id, p.to.place_id),
  );
  const alreadyCached = await loadCachedPairKeys(
    admin,
    cityProfileId,
    pairKeys,
  );
  const uncached = consecutive.filter(
    (p) => !alreadyCached.has(pairKey(p.from.place_id, p.to.place_id)),
  );
  if (uncached.length === 0) return;

  const mapboxToken =
    typeof Deno !== "undefined" && typeof Deno.env?.get === "function"
      ? (Deno.env.get("MAPBOX_ACCESS_TOKEN") ?? "")
      : "";

  const nowIso = new Date().toISOString();

  async function upsertRows(rows: TravelTimeInsertRow[]): Promise<void> {
    if (rows.length === 0) return;
    const { error } = await admin.from("city_travel_times").upsert(rows, {
      onConflict: "city_profile_id,from_place_id,to_place_id",
    });
    if (error) {
      console.warn("[travel-cache] upsert failed:", error.message);
    }
  }

  if (mapboxToken.trim().length > 0) {
    const settled = await Promise.allSettled(
      uncached.map(async ({ from, to }) => {
        const leg = await fetchMapboxDrivingLeg(
          { lat: from.lat, lng: from.lng },
          { lat: to.lat, lng: to.lng },
          mapboxToken.trim(),
        );
        return {
          city_profile_id: cityProfileId,
          from_place_id: from.place_id.trim(),
          to_place_id: to.place_id.trim(),
          driving_minutes: leg.drivingMinutes,
          walking_minutes: null,
          distance_meters: leg.distanceMeters,
          provider: "mapbox" as const,
          computed_at: nowIso,
        };
      }),
    );

    const mapboxRows: TravelTimeInsertRow[] = [];
    for (let i = 0; i < settled.length; i++) {
      const s = settled[i]!;
      if (s.status === "fulfilled") {
        mapboxRows.push(s.value);
      }
    }
    await upsertRows(mapboxRows);
    console.log(
      `[travel-cache] Mapbox Directions: stored ${mapboxRows.length}/${uncached.length} legs`,
    );

    if (mapboxRows.length === uncached.length) return;

    const ok = new Set(
      mapboxRows.map((r) => pairKey(r.from_place_id, r.to_place_id)),
    );
    const failed = uncached.filter(
      (p) => !ok.has(pairKey(p.from.place_id, p.to.place_id)),
    );
    console.warn(
      `[travel-cache] ${failed.length} Mapbox leg(s) failed, trying Google Routes`,
    );
    await fetchGoogleAndUpsert(admin, cityProfileId, failed, nowIso);
    return;
  }

  console.warn("[travel-cache] No MAPBOX_ACCESS_TOKEN; using Google Routes for all uncached legs");
  await fetchGoogleAndUpsert(admin, cityProfileId, uncached, nowIso);
}

async function fetchGoogleAndUpsert(
  admin: SupabaseClient,
  cityProfileId: string,
  pairs: Array<{ from: TTDPStop; to: TTDPStop }>,
  computedAtIso: string,
): Promise<void> {
  const rows = await Promise.all(
    pairs.map(async ({ from, to }) => {
      try {
        const route = await cachedDirections(
          { lat: from.lat, lng: from.lng },
          { lat: to.lat, lng: to.lng },
          "driving",
        );
        if (route.durationSeconds == null) {
          console.error(
            `[travel-cache] Google returned no duration for ${from.place_id} -> ${to.place_id}`,
          );
          return null;
        }
        return {
          city_profile_id: cityProfileId,
          from_place_id: from.place_id.trim(),
          to_place_id: to.place_id.trim(),
          driving_minutes: Math.max(
            1,
            Math.round(route.durationSeconds / 60),
          ),
          walking_minutes: null,
          distance_meters: route.distanceMeters != null
            ? Math.round(route.distanceMeters)
            : null,
          provider: "google" as const,
          computed_at: computedAtIso,
        } satisfies TravelTimeInsertRow;
      } catch (e) {
        console.error(
          `[travel-cache] Google Routes failed for ${from.place_id} -> ${to.place_id}:`,
          e,
        );
        return null;
      }
    }),
  );

  const toWrite = rows.filter((r): r is TravelTimeInsertRow => r != null);
  if (toWrite.length === 0) return;
  const { error } = await admin.from("city_travel_times").upsert(toWrite, {
    onConflict: "city_profile_id,from_place_id,to_place_id",
  });
  if (error) {
    console.warn("[travel-cache] Google upsert failed:", error.message);
  }
}



