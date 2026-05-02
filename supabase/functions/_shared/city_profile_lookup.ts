/**
 * City profile lookup for itinerary-ai: nearest DB profile by geo, optional auto-seed,
 * and scope helpers (Change 6 Part 2).
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  assignMinScope,
  assignTiersPerCategory,
  buildCityPlaceNearbyMealRows,
  buildSeedingQueries,
  inferCategoryFromTypes,
  passesQualityFilter,
  resolveCategoryFromVotes,
  SEEDING_TEXT_SEARCH_MAX_RESULTS,
  upsertCityPlaceNearbyMealRows,
} from "./city_places_seed_helpers.ts";
import { haversineKm } from "./day_plan_candidate_rank_core.ts";

type SupabaseAdmin = ReturnType<typeof createClient>;

const NEW_PLACES_BASE = "https://places.googleapis.com/v1";
const TEXT_SEARCH_FIELD_MASK =
  "places.id,places.displayName,places.formattedAddress,places.location,places.types";

const TEXT_SEARCH_BATCH_SIZE = 5;

/** Google Places API (New) `locationBias.circle.radius` max (meters). Seeding uses larger Wayfind radii — clamp here. @see https://developers.google.com/maps/documentation/places/web-service/text-search */
const GOOGLE_PLACES_TEXT_SEARCH_MAX_CIRCLE_RADIUS_M = 50_000;

export type CityProfile = {
  id: string;
  city_slug: string;
  display_name: string;
  country_code: string;
  center_lat: number;
  center_lng: number;
  match_radius_km: number;
  city_search_label: string;
  walkable_radius_m: number;
  city_wide_radius_m: number;
  spread_out_radius_m: number;
  walkable_dist_cap_km: number;
  city_wide_dist_cap_km: number;
  spread_out_dist_cap_km: number;
  cluster_radius_km: number;
  walkable_max_route_km: number;
  city_wide_max_route_km: number;
  spread_out_max_route_km: number;
  transit_note: string | null;
  neighborhoods: string[] | null;
};

export type CityPlaceCategory =
  | "attraction"
  | "restaurant"
  | "nature"
  | "shopping"
  | "nightlife"
  | "custom";

export type CityPlaceMinScope = "walkable" | "city_wide" | "spread_out";

/** Pre-fetched pool row shape returned to itinerary-ai (Change 7 Part 8). */
export type CityPlace = {
  place_id: string;
  name: string;
  lat: number;
  lng: number;
  category: CityPlaceCategory;
  min_scope: CityPlaceMinScope;
  tier: number;
  formatted_address: string | null;
  types: string[];
};

/** @deprecated use {@link CityPlace} */
export type CityAnchorPlace = CityPlace;

export type CityProfileWithPlaces = CityProfile & {
  places: CityPlace[];
};

const SCOPE_HIERARCHY: Record<string, number> = {
  walkable: 0,
  city_wide: 1,
  spread_out: 2,
};

/**
 * Generate a URL-safe slug from a city name, handling diacritics and special characters.
 * "São Paulo" → "sao-paulo", "Zürich" → "zurich", "New York" → "new-york"
 */
function toSlug(name: string): string {
  return name
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "");
}

export function deriveCityLabel(baseLabel: string): string {
  const parts = baseLabel.split(",").map((s) => s.trim());
  if (parts.length >= 3) {
    return parts
      .slice(1)
      .filter((p) => !/^\d{5}/.test(p))
      .join(", ");
  }
  return baseLabel;
}

export function getProfileRadius(profile: CityProfile, scope: string): number {
  switch (scope) {
    case "walkable":
      return profile.walkable_radius_m;
    case "city_wide":
      return profile.city_wide_radius_m;
    case "spread_out":
      return profile.spread_out_radius_m;
    default:
      return profile.city_wide_radius_m;
  }
}

export function getProfileDistCap(profile: CityProfile, scope: string): number {
  switch (scope) {
    case "walkable":
      return profile.walkable_dist_cap_km;
    case "city_wide":
      return profile.city_wide_dist_cap_km;
    case "spread_out":
      return profile.spread_out_dist_cap_km;
    default:
      return profile.city_wide_dist_cap_km;
  }
}

export function getProfileMaxRouteKm(
  profile: CityProfile,
  scope: string,
): number {
  switch (scope) {
    case "walkable":
      return profile.walkable_max_route_km;
    case "city_wide":
      return profile.city_wide_max_route_km;
    case "spread_out":
      return profile.spread_out_max_route_km;
    default:
      return profile.city_wide_max_route_km;
  }
}

export function filterPlacesForScope(
  places: CityPlace[],
  scope: string,
  center: { lat: number; lng: number },
  distCapKm: number,
): CityPlace[] {
  const scopeLevel = SCOPE_HIERARCHY[scope] ?? 1;
  return places.filter((a) => {
    const placeLevel = SCOPE_HIERARCHY[a.min_scope] ?? 1;
    if (placeLevel > scopeLevel) return false;
    const d = haversineKm(center, { lat: a.lat, lng: a.lng });
    return d <= distCapKm;
  });
}

/** @deprecated use {@link filterPlacesForScope} */
export function filterAnchorsForScope(
  anchors: CityPlace[],
  scope: string,
  center: { lat: number; lng: number },
  distCapKm: number,
): CityPlace[] {
  return filterPlacesForScope(anchors, scope, center, distCapKm);
}

/** Valid geocode result types that represent a real city/region (not a street or business). */
const SEEDABLE_GEOCODE_TYPES = new Set([
  "locality",
  "administrative_area_level_1",
  "administrative_area_level_2",
  "country",
  "colloquial_area",
  "sublocality",
  "sublocality_level_1",
  "neighborhood",
  "island",
]);

type GeocodeAddressComponent = {
  long_name: string;
  short_name: string;
  types: string[];
};

async function fetchTextSearchAnchors(
  apiKey: string,
  textQuery: string,
  profileCenter: { lat: number; lng: number },
  radiusMeters: number,
  includedType?: string,
  logPhase = "text_search",
): Promise<Array<Record<string, unknown>>> {
  const requestedRadius = Math.round(Number(radiusMeters));
  const circleRadius = Math.min(
    Math.max(0, requestedRadius),
    GOOGLE_PLACES_TEXT_SEARCH_MAX_CIRCLE_RADIUS_M,
  );
  const body: Record<string, unknown> = {
    textQuery,
    maxResultCount: SEEDING_TEXT_SEARCH_MAX_RESULTS,
    locationBias: {
      circle: {
        center: {
          latitude: profileCenter.lat,
          longitude: profileCenter.lng,
        },
        radius: circleRadius,
      },
    },
  };
  if (includedType?.trim()) {
    body.includedType = includedType.trim();
  }
  console.log(
    JSON.stringify({
      tag: "city_profile_seed_text_search_req",
      phase: logPhase,
      textQuery,
      includedType: includedType?.trim() ?? null,
      center: { lat: profileCenter.lat, lng: profileCenter.lng },
      radiusMeters: circleRadius,
      ...(requestedRadius !== circleRadius
        ? { radiusMetersRequested: requestedRadius }
        : {}),
    }),
  );
  const res = await fetch(`${NEW_PLACES_BASE}/places:searchText`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Goog-Api-Key": apiKey,
      "X-Goog-FieldMask": TEXT_SEARCH_FIELD_MASK,
    },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    let errSnippet = "";
    try {
      errSnippet = (await res.clone().text()).slice(0, 500);
    } catch {
      // ignore
    }
    console.log(
      JSON.stringify({
        tag: "city_profile_seed_text_search_http_err",
        phase: logPhase,
        textQuery,
        includedType: includedType?.trim() ?? null,
        status: res.status,
        bodySnippet: errSnippet,
      }),
    );
    console.log(
      JSON.stringify({
        tag: "city_profile_seed_text_search_res",
        phase: logPhase,
        textQuery,
        includedType: includedType?.trim() ?? null,
        placeCount: 0,
        previews: [],
        note: "http_error_no_places",
      }),
    );
    return [];
  }
  let data: { places?: Array<Record<string, unknown>> };
  try {
    data = (await res.json()) as { places?: Array<Record<string, unknown>> };
  } catch {
    console.log(
      JSON.stringify({
        tag: "city_profile_seed_text_search_res",
        phase: logPhase,
        textQuery,
        includedType: includedType?.trim() ?? null,
        placeCount: 0,
        previews: [],
        note: "json_parse_failed",
      }),
    );
    return [];
  }
  const places = data.places ?? [];
  const previews = places.slice(0, 6).map((p) => {
    const dn = p.displayName as { text?: string } | undefined;
    const types = (p.types as string[]) ?? [];
    return {
      name: String(dn?.text ?? "").slice(0, 100),
      types: types.slice(0, 12),
    };
  });
  console.log(
    JSON.stringify({
      tag: "city_profile_seed_text_search_res",
      phase: logPhase,
      textQuery,
      includedType: includedType?.trim() ?? null,
      placeCount: places.length,
      previews,
      ...(places.length === 0 ? { note: "zero_places_returned" } : {}),
    }),
  );
  return places;
}

/**
 * Look up an existing city profile: exact `city_slug` from base label first, then nearest
 * profile within a **10 km** proximity cap (suburb / neighborhood scale). Places are not
 * loaded here — `city_places` is queried geographically in `day_plan_candidate_pipeline`.
 *
 * If no match is found AND baseLabel is provided, attempt to auto-seed a new profile
 * using Google APIs + GPT so that the current request (and all future requests
 * for this city) benefit from city-specific parameters.
 */
export async function matchCityProfile(
  admin: SupabaseAdmin,
  center: { lat: number; lng: number },
  baseLabel?: string,
): Promise<CityProfile | null> {
  if (baseLabel?.trim()) {
    const cityName = baseLabel.split(",")[0]?.trim() || baseLabel.trim();
    const targetSlug = toSlug(cityName);

    const { data: exactMatch } = await admin
      .from("city_profiles")
      .select("*")
      .eq("city_slug", targetSlug)
      .maybeSingle();

    if (exactMatch) {
      const row = exactMatch as CityProfile;
      console.log(
        `[city_profile] exact slug match: ${row.display_name} (${row.city_slug})`,
      );
      return row;
    }
  }

  const { data: profiles } = await admin.from("city_profiles").select("*");

  if (profiles?.length) {
    let best: CityProfile | null = null;
    let bestDist = Infinity;

    for (const row of profiles) {
      const p = row as CityProfile;
      const d = haversineKm(center, { lat: p.center_lat, lng: p.center_lng });
      const radius = 10; // km — suburbs / neighborhoods only (not DB match_radius_km)
      if (d < bestDist && d <= radius) {
        bestDist = d;
        best = p;
      }
    }

    if (best) {
      return best;
    }
  }

  if (!baseLabel?.trim()) return null;

  try {
    const seeded = await autoSeedCityProfile(admin, center, baseLabel.trim());
    if (seeded) {
      console.log(
        `[city_profile] auto-seeded new profile: ${seeded.display_name} (${seeded.city_slug})`,
      );
      return seeded;
    }
  } catch (e) {
    console.error(
      "[city_profile] auto-seed failed, falling back to default profile",
      e,
    );
  }

  return null;
}

/**
 * Auto-seed a city profile on the fly when a user plans a trip to a city
 * not yet in the city_profiles table.
 *
 * Uses Google Geocoding (viewport for params), 14× Places Text Search (full pool),
 * and GPT-4.1-mini (transit note). Persists to `city_places` (Change 7 Part 7).
 */
async function autoSeedCityProfile(
  admin: SupabaseAdmin,
  center: { lat: number; lng: number },
  baseLabel: string,
): Promise<CityProfileWithPlaces | null> {
  const GOOGLE_API_KEY = Deno.env.get("GOOGLE_MAPS_API_KEY") ?? "";
  const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY") ?? "";
  if (!GOOGLE_API_KEY) return null;

  const geoUrl =
    `https://maps.googleapis.com/maps/api/geocode/json` +
    `?latlng=${center.lat},${center.lng}&key=${GOOGLE_API_KEY}`;
  const geoRes = await fetch(geoUrl);
  if (!geoRes.ok) return null;
  const geoData = (await geoRes.json()) as {
    results: Array<Record<string, unknown>>;
  };
  const geoResults = geoData.results ?? [];

  const cityResult = geoResults.find((r) => {
    const types = (r.types as string[]) ?? [];
    return types.some((t) => SEEDABLE_GEOCODE_TYPES.has(t));
  });
  if (!cityResult) return null;

  const geo = cityResult.geometry as Record<string, unknown> | undefined;
  const viewport = geo?.viewport as
    | {
        northeast: { lat: number; lng: number };
        southwest: { lat: number; lng: number };
      }
    | undefined;
  if (!viewport) return null;

  const geoCenter = geo?.location as { lat: number; lng: number } | undefined;
  const profileCenter = geoCenter ?? center;

  const components =
    (cityResult.address_components as GeocodeAddressComponent[] | undefined) ??
    [];

  const findComponent = (
    ...targetTypes: string[]
  ): GeocodeAddressComponent | undefined =>
    components.find((c) => c.types.some((t) => targetTypes.includes(t)));

  const localityComp =
    findComponent("locality") ??
    findComponent("administrative_area_level_2") ??
    findComponent("administrative_area_level_1") ??
    findComponent("colloquial_area", "island");

  const countryComp = findComponent("country");
  const adminComp = findComponent("administrative_area_level_1");

  const cityName =
    localityComp?.long_name ??
    (String(cityResult.formatted_address ?? baseLabel).split(",")[0]?.trim() ||
      baseLabel);

  const countryCode = countryComp?.short_name ?? "";

  const searchLabelParts = [cityName];
  if (adminComp && adminComp.long_name !== cityName) {
    searchLabelParts.push(adminComp.long_name);
  } else if (countryComp) {
    searchLabelParts.push(countryComp.long_name);
  }
  /** From geocode only — used for slug/display consistency. */
  const geoSearchLabel = searchLabelParts.join(", ");
  /**
   * User-facing area (e.g. first segment of stay label "Uluwatu, …") prepended when it
   * refines the geocoder label so Text Search queries mention both (e.g. "Uluwatu, Badung Regency, Bali").
   */
  const userPlaceHead =
    baseLabel.split(",")[0]?.trim().replace(/\s+/g, " ") ?? "";
  const seedingSearchLabel =
    userPlaceHead.length > 0 &&
      userPlaceHead.toLowerCase() !== cityName.toLowerCase() &&
      !geoSearchLabel.toLowerCase().includes(userPlaceHead.toLowerCase())
      ? `${userPlaceHead}, ${geoSearchLabel}`
      : geoSearchLabel;

  const slug = toSlug(cityName);

  const { data: existing } = await admin
    .from("city_profiles")
    .select("id")
    .eq("city_slug", slug)
    .maybeSingle();
  if (existing) {
    // Re-enter via slug so we return the existing row even when `center` is >10 km from
    // `city_profiles.center_*` (proximity-only match would miss).
    return matchCityProfile(admin, center, cityName);
  }

  const diagKm = haversineKm(
    { lat: viewport.northeast.lat, lng: viewport.northeast.lng },
    { lat: viewport.southwest.lat, lng: viewport.southwest.lng },
  );
  const compactness = Math.min(1, diagKm / 150);
  const round1 = (n: number) => Math.round(n * 10) / 10;

  const params = {
    walkable_radius_m: Math.round(3000 + compactness * 3000),
    city_wide_radius_m: Math.round(12000 + compactness * 18000),
    spread_out_radius_m: Math.round(40000 + compactness * 40000),
    walkable_dist_cap_km: round1(4 + compactness * 6),
    city_wide_dist_cap_km: round1(15 + compactness * 20),
    spread_out_dist_cap_km: round1(40 + compactness * 60),
    cluster_radius_km: round1(2 + compactness * 4),
    walkable_max_route_km: round1(6 + compactness * 10),
    city_wide_max_route_km: round1(25 + compactness * 30),
    spread_out_max_route_km: round1(80 + compactness * 70),
  };

  type AutoseedHit = {
    place_id: string;
    name: string;
    lat: number;
    lng: number;
    formatted_address: string;
    types: string[];
  };

  function parseTextSearchPlace(
    p: Record<string, unknown>,
  ): AutoseedHit | null {
    const rawId = String(p.id ?? "").trim();
    const placeId = rawId.replace(/^places\//, "");
    if (!placeId) return null;
    const dn = p.displayName as { text?: string } | undefined;
    const loc = p.location as
      | { latitude?: number; longitude?: number }
      | undefined;
    const name = dn?.text?.trim() ?? "";
    const lat = loc?.latitude;
    const lng = loc?.longitude;
    if (!name || typeof lat !== "number" || typeof lng !== "number") {
      return null;
    }
    const types = (p.types as string[]) ?? [];
    const fa = String(p.formattedAddress ?? "").trim();
    return {
      place_id: placeId,
      name,
      lat,
      lng,
      formatted_address: fa,
      types,
    };
  }

  type DedupEntry = {
    hit: AutoseedHit;
    sourceQueryCount: number;
    firstSourceQuery: string;
    categoryVotes: Map<string, number>;
  };

  const deduped = new Map<string, DedupEntry>();
  const seedingSpecs = buildSeedingQueries(seedingSearchLabel);

  console.log(
    JSON.stringify({
      tag: "city_profile_seed_run_start",
      geoSearchLabel,
      seedingSearchLabel,
      citySlug: slug,
      displayName: cityName,
      profileCenter,
      spreadOutRadiusM: params.spread_out_radius_m,
      cityWideRadiusM: params.city_wide_radius_m,
      mainQuerySpecCount: seedingSpecs.length,
    }),
  );

  for (let i = 0; i < seedingSpecs.length; i += TEXT_SEARCH_BATCH_SIZE) {
    const slice = seedingSpecs.slice(i, i + TEXT_SEARCH_BATCH_SIZE);
    const batchHits = await Promise.all(
      slice.map((spec, idx) =>
        fetchTextSearchAnchors(
          GOOGLE_API_KEY,
          spec.query,
          profileCenter,
          params.spread_out_radius_m,
          spec.includedType,
          `main_batch_${i}_q_${idx}`,
        ),
      ),
    );
    for (let b = 0; b < slice.length; b++) {
      const spec = slice[b]!;
      const places = batchHits[b] ?? [];
      let accepted = 0;
      let parseFailed = 0;
      let filterRejected = 0;
      for (const raw of places) {
        const p = raw as Record<string, unknown>;
        const hit = parseTextSearchPlace(p);
        if (!hit) {
          parseFailed += 1;
          continue;
        }
        if (!passesQualityFilter(hit.name, hit.types)) {
          filterRejected += 1;
          continue;
        }
        accepted += 1;
        const inferredCat = inferCategoryFromTypes(hit.types);
        const existing = deduped.get(hit.place_id);
        if (existing) {
          existing.sourceQueryCount += 1;
          existing.categoryVotes.set(
            inferredCat,
            (existing.categoryVotes.get(inferredCat) ?? 0) + 1,
          );
        } else {
          deduped.set(hit.place_id, {
            hit,
            sourceQueryCount: 1,
            firstSourceQuery: spec.query,
            categoryVotes: new Map([[inferredCat, 1]]),
          });
        }
      }
      console.log(
        JSON.stringify({
          tag: "city_profile_seed_spec_summary",
          phase: "main",
          targetCategory: spec.targetCategory,
          textQuery: spec.query,
          includedType: spec.includedType ?? null,
          rawPlacesReturned: places.length,
          acceptedAfterParseAndFilter: accepted,
          parseFailed,
          filterRejected,
        }),
      );
    }
  }

  // --- Offset restaurant searches: fan out from city center to cover neighborhoods ---
  // Uses 4 offset points (N/S/E/W) at 40% of city_wide_dist_cap_km from center.
  // This ensures restaurants are distributed across the city, not just clustered at the center.
  const offsetDistKm = params.city_wide_dist_cap_km * 0.4;
  const latOffsetDeg = offsetDistKm / 111.32;
  const lngOffsetDeg = offsetDistKm / (111.32 * Math.cos((profileCenter.lat * Math.PI) / 180));

  const offsetCenters = [
    { lat: profileCenter.lat + latOffsetDeg, lng: profileCenter.lng },             // North
    { lat: profileCenter.lat - latOffsetDeg, lng: profileCenter.lng },             // South
    { lat: profileCenter.lat, lng: profileCenter.lng + lngOffsetDeg },             // East
    { lat: profileCenter.lat, lng: profileCenter.lng - lngOffsetDeg },             // West
  ];

  const offsetMealQueries = offsetCenters.map((oc) => ({
    center: oc,
    query: `restaurants in ${seedingSearchLabel}`,
    includedType: "restaurant",
  }));

  const offsetBatchHits = await Promise.all(
    offsetMealQueries.map((q, idx) =>
      fetchTextSearchAnchors(
        GOOGLE_API_KEY,
        q.query,
        q.center,
        params.city_wide_radius_m,
        q.includedType,
        `offset_restaurant_${idx}`,
      ),
    ),
  );

  for (let b = 0; b < offsetMealQueries.length; b++) {
    const places = offsetBatchHits[b] ?? [];
    let accepted = 0;
    let parseFailed = 0;
    let filterRejected = 0;
    for (const raw of places) {
      const p = raw as Record<string, unknown>;
      const hit = parseTextSearchPlace(p);
      if (!hit) {
        parseFailed += 1;
        continue;
      }
      if (!passesQualityFilter(hit.name, hit.types)) {
        filterRejected += 1;
        continue;
      }
      accepted += 1;
      const inferredCat = inferCategoryFromTypes(hit.types);
      const existing = deduped.get(hit.place_id);
      if (existing) {
        existing.sourceQueryCount += 1;
        existing.categoryVotes.set(
          inferredCat,
          (existing.categoryVotes.get(inferredCat) ?? 0) + 1,
        );
      } else {
        deduped.set(hit.place_id, {
          hit,
          sourceQueryCount: 1,
          firstSourceQuery: `offset_restaurant_${b}`,
          categoryVotes: new Map([[inferredCat, 1]]),
        });
      }
    }
    console.log(
      JSON.stringify({
        tag: "city_profile_seed_spec_summary",
        phase: "offset_restaurant",
        offsetIndex: b,
        textQuery: offsetMealQueries[b]!.query,
        includedType: offsetMealQueries[b]!.includedType ?? null,
        offsetCenter: offsetCenters[b],
        rawPlacesReturned: places.length,
        acceptedAfterParseAndFilter: accepted,
        parseFailed,
        filterRejected,
      }),
    );
  }

  let transitNote: string | null = null;
  if (OPENAI_API_KEY) {
    try {
      const gptRes = await fetch("https://api.openai.com/v1/chat/completions", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${OPENAI_API_KEY}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          model: "gpt-4.1-mini",
          temperature: 0.3,
          max_tokens: 150,
          messages: [
            {
              role: "user",
              content:
                `Write exactly one practical sentence about the best transit options for tourists in ${cityName}. ` +
                `Include the main mode of transport and any card/pass recommendation. Be concise.`,
            },
          ],
        }),
      });
      if (gptRes.ok) {
        const gptData = (await gptRes.json()) as {
          choices: Array<{ message: { content: string } }>;
        };
        transitNote = gptData.choices?.[0]?.message?.content?.trim() ?? null;
      }
    } catch {
      // Non-critical — profile still works without transit note
    }
  }

  const { data: profile, error: profileErr } = await admin
    .from("city_profiles")
    .upsert(
      {
        city_slug: slug,
        display_name: cityName,
        country_code: countryCode,
        center_lat: profileCenter.lat,
        center_lng: profileCenter.lng,
        match_radius_km: 50,
        city_search_label: seedingSearchLabel,
        ...params,
        transit_note: transitNote,
      },
      { onConflict: "city_slug" },
    )
    .select("id")
    .single();

  if (profileErr || !profile) return null;

  type MergedPlaceRow = {
    hit: AutoseedHit;
    wayfind_category: string;
    source_query_count: number;
    first_source_query: string;
    dist_from_center_km: number;
    min_scope: CityPlaceMinScope;
    tier: 1 | 2 | 3;
  };

  const mergedPlaces = new Map<string, MergedPlaceRow>();
  for (const [, ent] of deduped) {
    const wayfind_category = resolveCategoryFromVotes(ent.categoryVotes);
    const dist = haversineKm(profileCenter, {
      lat: ent.hit.lat,
      lng: ent.hit.lng,
    });
    mergedPlaces.set(ent.hit.place_id, {
      hit: ent.hit,
      wayfind_category,
      source_query_count: ent.sourceQueryCount,
      first_source_query: ent.firstSourceQuery,
      dist_from_center_km: dist,
      min_scope: assignMinScope(dist, params.walkable_dist_cap_km, params.city_wide_dist_cap_km),
      tier: 2,
    });
  }
  assignTiersPerCategory(mergedPlaces);

  const byCategory: Record<string, number> = {};
  for (const row of mergedPlaces.values()) {
    const c = row.wayfind_category;
    byCategory[c] = (byCategory[c] ?? 0) + 1;
  }
  console.log(
    JSON.stringify({
      tag: "city_profile_seed_final_pool",
      citySlug: slug,
      uniquePlaceCount: mergedPlaces.size,
      byCategory,
    }),
  );

  await admin.from("city_place_nearby_meals").delete().eq(
    "city_profile_id",
    profile.id,
  );
  await admin.from("city_places").delete().eq("city_profile_id", profile.id);

  const insertPayload = [...mergedPlaces.values()].map((row) => ({
    city_profile_id: profile.id,
    place_id: row.hit.place_id,
    name: row.hit.name,
    lat: row.hit.lat,
    lng: row.hit.lng,
    formatted_address: row.hit.formatted_address.length > 0
      ? row.hit.formatted_address
      : null,
    types: row.hit.types,
    wayfind_category: row.wayfind_category,
    min_scope: row.min_scope,
    tier: row.tier,
    source_query_count: row.source_query_count,
    dist_from_center_km: round1(row.dist_from_center_km),
    source_query: row.first_source_query,
    status: "active",
    last_refreshed_at: new Date().toISOString(),
  }));

  const CHUNK = 100;
  let cityPlacesInsertOk = true;
  for (let i = 0; i < insertPayload.length; i += CHUNK) {
    const chunk = insertPayload.slice(i, i + CHUNK);
    if (!chunk.length) continue;
    const { error: insErr } = await admin.from("city_places").insert(chunk);
    if (insErr) {
      console.error("[city_profile] city_places insert failed", insErr);
      cityPlacesInsertOk = false;
    }
  }

  if (cityPlacesInsertOk && insertPayload.length > 0) {
    try {
      const mealRows = buildCityPlaceNearbyMealRows(
        profile.id as string,
        [...mergedPlaces.values()].map((row) => ({
          place_id: row.hit.place_id,
          lat: row.hit.lat,
          lng: row.hit.lng,
          wayfind_category: row.wayfind_category,
        })),
        params.city_wide_dist_cap_km,
      );
      if (mealRows.length > 0) {
        await upsertCityPlaceNearbyMealRows(admin, mealRows);
        console.log(
          `[city_profile] city_place_nearby_meals: upserted ${mealRows.length} rows (haversine)`,
        );
      }
    } catch (e) {
      console.warn("[city_profile] nearby meals seed failed:", e);
    }
  }

  const places: CityPlace[] = [...mergedPlaces.values()]
    .sort((a, b) => {
      const c = a.wayfind_category.localeCompare(b.wayfind_category);
      if (c !== 0) return c;
      if (a.tier !== b.tier) return a.tier - b.tier;
      if (b.source_query_count !== a.source_query_count) {
        return b.source_query_count - a.source_query_count;
      }
      return a.hit.name.localeCompare(b.hit.name);
    })
    .map((row) => ({
      place_id: row.hit.place_id,
      name: row.hit.name,
      lat: row.hit.lat,
      lng: row.hit.lng,
      category: row.wayfind_category as CityPlaceCategory,
      min_scope: row.min_scope,
      tier: row.tier,
      formatted_address: row.hit.formatted_address.length > 0
        ? row.hit.formatted_address
        : null,
      types: row.hit.types,
    }));

  return {
    id: profile.id as string,
    city_slug: slug,
    display_name: cityName,
    country_code: countryCode,
    center_lat: profileCenter.lat,
    center_lng: profileCenter.lng,
    match_radius_km: 50,
    city_search_label: seedingSearchLabel,
    ...params,
    transit_note: transitNote,
    neighborhoods: null,
    places,
  };
}

export function buildDefaultProfile(baseLabel: string): CityProfile {
  return {
    id: "default",
    city_slug: "default",
    display_name: baseLabel,
    country_code: "",
    center_lat: 0,
    center_lng: 0,
    match_radius_km: 50,
    city_search_label: deriveCityLabel(baseLabel),
    walkable_radius_m: 4000,
    city_wide_radius_m: 20000,
    spread_out_radius_m: 60000,
    walkable_dist_cap_km: 5,
    city_wide_dist_cap_km: 25,
    spread_out_dist_cap_km: 80,
    cluster_radius_km: 3,
    walkable_max_route_km: 8,
    city_wide_max_route_km: 35,
    spread_out_max_route_km: 120,
    transit_note: null,
    neighborhoods: null,
  };
}



