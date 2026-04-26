-- Link trips → city_profiles directly.
--
-- Problem: trips had no FK into city_profiles, so every map screen,
-- search fan-out, and AI itinerary call had to re-run a 3-tier guess
-- (slug → geo proximity → place_id lookup) to discover city_profile_id.
-- Geo proximity (tier 2) was dead code because lat/lng were never stored.
--
-- This migration:
--   1. Adds city_profile_id FK, lat, lng to trips.
--   2. Backfills existing rows via the same 3-tier ladder.
--   3. Exposes the new columns to authenticated clients.
--
-- After applying: TripRow reads city_profile_id/lat/lng; TripMapView
-- seeds resolvedCityProfileId and searchRegion from the trip directly
-- instead of running an async resolver on every map open.

-- Slug backfill uses unaccent (not enabled by default on fresh projects).
CREATE EXTENSION IF NOT EXISTS unaccent WITH SCHEMA extensions;

-- 1. New columns. All nullable — not all trips have a known city profile.
ALTER TABLE public.trips
  ADD COLUMN IF NOT EXISTS city_profile_id uuid
    REFERENCES public.city_profiles (id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS lat double precision,
  ADD COLUMN IF NOT EXISTS lng double precision;

CREATE INDEX IF NOT EXISTS idx_trips_city_profile_id
  ON public.trips (city_profile_id);

-- 2a. Backfill Tier 1: slug match.
--
-- Mirrors SupabaseManager.cityProfileSlug:
--   • unaccent: strip diacritics  (e.g. "Zürich" → "Zurich")
--   • lower + regexp_replace:     non-alphanum runs → single hyphen
--   • trailing hyphen stripped
--
-- Only the first comma-segment of destination is used
-- (e.g. "Paris, France" → "paris", "Le Marais, Paris" → "le-marais").
UPDATE public.trips t
SET city_profile_id = cp.id,
    lat             = cp.center_lat,
    lng             = cp.center_lng
FROM public.city_profiles cp
WHERE t.city_profile_id IS NULL
  AND regexp_replace(
        regexp_replace(
          lower(extensions.unaccent(trim(split_part(t.destination, ',', 1)))),
          '[^a-z0-9]+', '-', 'g'
        ),
        '-$', ''
      ) = cp.city_slug;

-- 2b. Backfill Tier 2: destination_place_id → city_places → city_profile.
--
-- Catches trips whose destination is a seeded POI (resort, landmark,
-- specific venue) where the slug won't match a city_profiles.city_slug.
UPDATE public.trips t
SET city_profile_id = cp.id,
    lat             = cp.center_lat,
    lng             = cp.center_lng
FROM public.city_places cpx
JOIN public.city_profiles cp ON cp.id = cpx.city_profile_id
WHERE t.city_profile_id IS NULL
  AND t.destination_place_id IS NOT NULL
  AND t.destination_place_id = cpx.place_id;

-- 3. Grant read access to authenticated clients.
--    Row-level RLS on trips already governs which rows each user sees.
GRANT SELECT (city_profile_id, lat, lng) ON public.trips TO authenticated;

-- Note: tier 3 (geo proximity) can't be backfilled here because trip rows
-- don't yet carry coordinates when city_profile_id is still NULL. The iOS
-- runtime resolver remains as the live fallback and will persist the result
-- via patchTripCityProfile after first resolution.
