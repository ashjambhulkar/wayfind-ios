import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  deriveCityLabel,
  matchCityProfile,
} from "../_shared/city_profile_lookup.ts";
import { haversineKm } from "../_shared/day_plan_candidate_rank_core.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Content-Type": "application/json",
};

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: CORS_HEADERS });
}

type WayfindCategory =
  | "attraction"
  | "restaurant"
  | "nature"
  | "shopping"
  | "nightlife"
  | "custom";

function toWayfindCategory(raw: unknown): WayfindCategory {
  const c = typeof raw === "string" ? raw.trim().toLowerCase() : "";
  if (
    c === "attraction" || c === "restaurant" || c === "nature" ||
    c === "shopping" || c === "nightlife" || c === "custom"
  ) {
    return c;
  }
  // `trip_activities.category` includes `transport`, which has no city_places analogue.
  return "custom";
}

/** Same locality/region notion as `autoSeedCityProfile` in city_profile_lookup.ts */
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

/**
 * When the client has no usable city string, derive one from coordinates so
 * `matchCityProfile` can run `autoSeedCityProfile` (Google geocode + text search +
 * bulk `city_places` inserts) — same requirement as itinerary-ai: non-empty `baseLabel`
 * before `autoSeedCityProfile` is invoked (see city_profile_lookup.ts).
 */
async function reverseGeocodeSeedLabel(
  lat: number,
  lng: number,
): Promise<string | null> {
  const key = Deno.env.get("GOOGLE_MAPS_API_KEY")?.trim();
  if (!key) return null;

  const geoUrl =
    `https://maps.googleapis.com/maps/api/geocode/json` +
    `?latlng=${lat},${lng}&key=${encodeURIComponent(key)}`;
  const geoRes = await fetch(geoUrl);
  if (!geoRes.ok) return null;
  const geoData = (await geoRes.json()) as {
    results?: Array<Record<string, unknown>>;
  };
  const geoResults = geoData.results ?? [];

  const cityResult = geoResults.find((r) => {
    const types = (r.types as string[]) ?? [];
    return types.some((t) => SEEDABLE_GEOCODE_TYPES.has(t));
  });
  if (!cityResult) return null;

  const fa = String(cityResult.formatted_address ?? "").trim();
  if (fa.length > 0) return fa;

  const components =
    (cityResult.address_components as GeocodeAddressComponent[] | undefined) ??
    [];
  const find = (...targetTypes: string[]) =>
    components.find((c) => c.types.some((t) => targetTypes.includes(t)));

  const locality =
    find("locality") ??
    find("administrative_area_level_2") ??
    find("administrative_area_level_1");
  const admin = find("administrative_area_level_1");
  const country = find("country");

  const cityName = locality?.long_name?.trim();
  if (!cityName) return null;

  const parts = [cityName];
  if (admin && admin.long_name !== cityName) parts.push(admin.long_name);
  else if (country) parts.push(country.long_name);
  return parts.join(", ");
}

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }

    const supabaseUser = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: userData, error: userErr } = await supabaseUser.auth.getUser();
    if (userErr || !userData?.user?.id) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }

    const body = await req.json() as Record<string, unknown>;
    const tripId = String(body.trip_id ?? "").trim();
    const placeId = String(body.place_id ?? "").trim();
    const lat = typeof body.lat === "number" ? body.lat : Number(body.lat);
    const lng = typeof body.lng === "number" ? body.lng : Number(body.lng);
    const name = String(body.name ?? "").trim();
    const formattedAddress = typeof body.formatted_address === "string"
      ? body.formatted_address.trim()
      : "";
    const types = Array.isArray(body.types)
      ? (body.types as unknown[]).map((t) => String(t))
      : [];

    if (!tripId || !placeId) {
      return jsonResponse(
        { error: "trip_id and place_id are required" },
        400,
      );
    }
    if (!Number.isFinite(lat) || !Number.isFinite(lng)) {
      return jsonResponse({ error: "lat and lng must be finite numbers" }, 400);
    }
    if (!name) {
      return jsonResponse({ error: "name is required" }, 400);
    }

    const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    const { data: isMember, error: memberRpcErr } = await admin.rpc(
      "is_trip_member",
      {
        p_trip_id: tripId,
        p_user_id: userData.user.id,
      },
    );
    if (memberRpcErr) {
      console.error("[sync-city-place-from-trip] is_trip_member", memberRpcErr.message);
      return jsonResponse({ error: "member_check_failed" }, 500);
    }
    if (!isMember) {
      return jsonResponse({ error: "Forbidden" }, 403);
    }

    const { data: tripRow, error: tripErr } = await admin
      .from("trips")
      .select("destination")
      .eq("id", tripId)
      .maybeSingle();
    if (tripErr || !tripRow) {
      return jsonResponse({ error: "Trip not found" }, 404);
    }

    const tripDest = typeof tripRow.destination === "string"
      ? tripRow.destination.trim()
      : "";

    const labelSource =
      formattedAddress ||
      name ||
      tripDest;
    let seedLabel =
      deriveCityLabel(labelSource).trim() ||
      labelSource.trim();

    // `matchCityProfile` only calls `autoSeedCityProfile` (Google pool + inserts) when
    // `baseLabel` is non-empty — mirror itinerary-ai / planner behavior for manual adds.
    if (!seedLabel) {
      seedLabel = (await reverseGeocodeSeedLabel(lat, lng)) ?? "";
    }
    if (!seedLabel.trim()) {
      seedLabel = `${lat.toFixed(5)},${lng.toFixed(5)}`;
    }

    const profile = await matchCityProfile(
      admin,
      { lat, lng },
      seedLabel.trim(),
    );

    if (!profile) {
      return jsonResponse({
        ok: true,
        skipped: true,
        reason: "no_city_profile",
      });
    }

    const wayfind_category = toWayfindCategory(body.activity_category);
    const dist = haversineKm(
      { lat, lng },
      { lat: profile.center_lat, lng: profile.center_lng },
    );

    const { error: upsertErr } = await admin.from("city_places").upsert(
      {
        city_profile_id: profile.id,
        place_id: placeId,
        name,
        lat,
        lng,
        formatted_address: formattedAddress || null,
        types: types.length ? types : [],
        wayfind_category,
        min_scope: "city_wide",
        tier: 3,
        source_query_count: 1,
        dist_from_center_km: dist,
        source_query: "user_trip_activity_add",
        status: "active",
        last_refreshed_at: new Date().toISOString(),
      },
      { onConflict: "city_profile_id,place_id" },
    );

    if (upsertErr) {
      console.error("[sync-city-place-from-trip] upsert", upsertErr.message);
      return jsonResponse({ error: upsertErr.message }, 500);
    }

    return jsonResponse({
      ok: true,
      city_profile_id: profile.id,
      place_id: placeId,
    });
  } catch (e) {
    console.error("[sync-city-place-from-trip]", e);
    return jsonResponse(
      { error: e instanceof Error ? e.message : "internal_error" },
      500,
    );
  }
});
