-- Precomputed origin → destination travel hints per city profile (walk / transit / drive).

CREATE TABLE public.city_travel_times (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  city_profile_id uuid NOT NULL REFERENCES public.city_profiles (id) ON DELETE CASCADE,
  from_place_id text NOT NULL,
  to_place_id text NOT NULL,
  walking_minutes integer,
  transit_minutes integer,
  driving_minutes integer,
  distance_meters integer,
  provider text NOT NULL DEFAULT 'haversine' CHECK (provider IN ('mapbox', 'google', 'haversine')),
  computed_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (city_profile_id, from_place_id, to_place_id)
);

CREATE INDEX idx_travel_times_lookup
  ON public.city_travel_times (city_profile_id, from_place_id, to_place_id);

ALTER TABLE public.city_travel_times ENABLE ROW LEVEL SECURITY;

CREATE POLICY travel_times_public_read ON public.city_travel_times
  FOR SELECT
  USING (true);

GRANT SELECT ON public.city_travel_times TO anon, authenticated;

COMMENT ON TABLE public.city_travel_times IS
  'Cached travel times and distance between two place_ids within a city profile (routing / itinerary).';
