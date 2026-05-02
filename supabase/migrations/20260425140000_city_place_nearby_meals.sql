-- Precomputed activity → nearby restaurant edges per city profile (AI / routing hints).

CREATE TABLE public.city_place_nearby_meals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  city_profile_id uuid NOT NULL REFERENCES public.city_profiles (id) ON DELETE CASCADE,
  activity_place_id text NOT NULL,
  restaurant_place_id text NOT NULL,
  distance_km double precision NOT NULL,
  walking_minutes_est integer NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (city_profile_id, activity_place_id, restaurant_place_id)
);

CREATE INDEX idx_nearby_meals_activity
  ON public.city_place_nearby_meals (city_profile_id, activity_place_id);

ALTER TABLE public.city_place_nearby_meals ENABLE ROW LEVEL SECURITY;

CREATE POLICY nearby_meals_public_read ON public.city_place_nearby_meals
  FOR SELECT
  USING (true);

GRANT SELECT ON public.city_place_nearby_meals TO anon, authenticated;

COMMENT ON TABLE public.city_place_nearby_meals IS
  'Precomputed pairs: non-restaurant activity place → nearby restaurant for a city profile.';
