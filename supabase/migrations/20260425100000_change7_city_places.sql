-- Change 7 Part 1: city_places — full pre-fetched pool per city (replaces anchor-only storage path over time).
-- Public read for Edge + clients; writes via service_role (bypasses RLS).

-- 1a. Table schema
CREATE TABLE public.city_places (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  city_profile_id uuid NOT NULL REFERENCES public.city_profiles (id) ON DELETE CASCADE,

  place_id text NOT NULL,

  name text NOT NULL,
  lat double precision NOT NULL,
  lng double precision NOT NULL,
  formatted_address text,
  types text[] DEFAULT '{}',

  wayfind_category text NOT NULL CHECK (wayfind_category IN
    ('attraction', 'restaurant', 'nature', 'shopping', 'nightlife', 'custom')),

  min_scope text NOT NULL DEFAULT 'city_wide' CHECK (min_scope IN
    ('walkable', 'city_wide', 'spread_out')),

  tier integer NOT NULL DEFAULT 2 CHECK (tier BETWEEN 1 AND 3),
  source_query_count integer NOT NULL DEFAULT 1,
  dist_from_center_km double precision,

  source_query text,

  status text NOT NULL DEFAULT 'active' CHECK (status IN
    ('active', 'reported', 'removed', 'stale')),
  reported_count integer NOT NULL DEFAULT 0,
  reported_at timestamptz,

  last_refreshed_at timestamptz NOT NULL DEFAULT now(),

  created_at timestamptz NOT NULL DEFAULT now(),

  UNIQUE (city_profile_id, place_id)
);

CREATE INDEX idx_city_places_query
  ON public.city_places (city_profile_id, status, wayfind_category, min_scope);

CREATE INDEX idx_city_places_refresh
  ON public.city_places (last_refreshed_at)
  WHERE status = 'active';

COMMENT ON TABLE public.city_places IS
  'Pre-fetched places pool per city for AI itinerary generation. '
  'Replaces runtime Google Places API calls. Seeded by batch script or auto-seed, '
  'refreshed every 30 days, cleaned by user reports.';

-- 1b. RLS
ALTER TABLE public.city_places ENABLE ROW LEVEL SECURITY;

CREATE POLICY city_places_public_read ON public.city_places
  FOR SELECT
  USING (true);

GRANT SELECT ON public.city_places TO anon, authenticated;
