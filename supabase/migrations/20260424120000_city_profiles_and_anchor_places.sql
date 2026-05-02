-- Change 6 Part 1 (1a–1c): city_profiles, city_anchor_places, public read RLS.
-- Reference data: readable by anon/authenticated (Edge Functions + clients); writes via service_role (bypasses RLS).

-- 1a. city_profiles
CREATE TABLE public.city_profiles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Identity
  city_slug text UNIQUE NOT NULL,
  display_name text NOT NULL,
  country_code text NOT NULL,

  -- Geographic center (for profile matching)
  center_lat double precision NOT NULL,
  center_lng double precision NOT NULL,
  match_radius_km double precision NOT NULL DEFAULT 50,

  -- City-level label for broad Google queries ("in {city}")
  city_search_label text NOT NULL,

  -- Scope-specific search radii (meters)
  walkable_radius_m integer NOT NULL DEFAULT 4000,
  city_wide_radius_m integer NOT NULL DEFAULT 20000,
  spread_out_radius_m integer NOT NULL DEFAULT 60000,

  -- Scope-specific distance caps (km) for filtering outliers
  walkable_dist_cap_km double precision NOT NULL DEFAULT 5,
  city_wide_dist_cap_km double precision NOT NULL DEFAULT 25,
  spread_out_dist_cap_km double precision NOT NULL DEFAULT 60,

  -- Clustering radius for geographic grouping (km)
  cluster_radius_km double precision NOT NULL DEFAULT 3,

  -- Route distance limits per scope (km) — total inter-stop distance
  walkable_max_route_km double precision NOT NULL DEFAULT 8,
  city_wide_max_route_km double precision NOT NULL DEFAULT 35,
  spread_out_max_route_km double precision NOT NULL DEFAULT 120,

  -- Transit guidance injected into prompt
  transit_note text,

  -- Neighborhoods (for future use — e.g., neighborhood selector UI)
  neighborhoods text[],

  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_city_profiles_geo ON public.city_profiles (center_lat, center_lng);

COMMENT ON TABLE public.city_profiles IS
  'Per-city tuning for AI itinerary generation: search radii, distance caps, '
  'route limits, and transit notes. Matched by geographic proximity to user base location.';

-- 1b. city_anchor_places
CREATE TABLE public.city_anchor_places (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  city_profile_id uuid NOT NULL REFERENCES public.city_profiles (id) ON DELETE CASCADE,

  -- Google Place ID (for injection into candidate pool)
  place_id text NOT NULL,
  name text NOT NULL,
  lat double precision NOT NULL,
  lng double precision NOT NULL,
  category text NOT NULL CHECK (category IN
    ('attraction', 'restaurant', 'nature', 'shopping', 'nightlife', 'custom')),

  -- Minimum scope required for this anchor to appear
  -- walkable: always included; city_wide: included in city_wide + spread_out; spread_out: only in spread_out
  min_scope text NOT NULL DEFAULT 'city_wide' CHECK (min_scope IN ('walkable', 'city_wide', 'spread_out')),

  -- Tier for ranking boost (1 = must-see, 2 = strong recommendation, 3 = nice-to-have)
  tier integer NOT NULL DEFAULT 2 CHECK (tier BETWEEN 1 AND 3),

  -- Optional formatted address for the prompt
  formatted_address text,

  -- Optional types array (matching Google types format)
  types text[] DEFAULT '{}',

  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_city_anchors_profile ON public.city_anchor_places (city_profile_id);

COMMENT ON TABLE public.city_anchor_places IS
  'Curated must-see places per city that are injected into the AI candidate pool '
  'to guarantee essential landmarks are always available regardless of Google search results.';

-- 1c. RLS: public read; no INSERT/UPDATE/DELETE for anon/authenticated (service_role bypasses RLS)
ALTER TABLE public.city_profiles ENABLE ROW LEVEL SECURITY;

CREATE POLICY city_profiles_public_read ON public.city_profiles
  FOR SELECT
  USING (true);

ALTER TABLE public.city_anchor_places ENABLE ROW LEVEL SECURITY;

CREATE POLICY city_anchors_public_read ON public.city_anchor_places
  FOR SELECT
  USING (true);

-- Allow Supabase API roles to read (RLS still restricts writes)
GRANT SELECT ON public.city_profiles TO anon, authenticated;
GRANT SELECT ON public.city_anchor_places TO anon, authenticated;
