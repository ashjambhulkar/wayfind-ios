-- Places cost-reduction plan, Phase C.1.
--
-- Bridges Apple MapKit hits (name + lat/lng, NO place_id) to Google place_ids
-- so the iOS app can grow `city_places` from any commit-intent action — even
-- those that started in MapKit. Uses PostGIS for real spatial proximity and
-- pg_trgm for fuzzy name match, since Apple and Google routinely disagree on
-- both the coordinate (10–50m) and the canonical name spelling.
--
-- Resolution order in the `lookup-place-id` Edge Function (Phase C.2):
--   1. city_places spatial+fuzzy (free, leverages our owned data)
--   2. place_id_bridge cache (free after first resolve)
--   3. Google Text Search Essentials with field mask `places.id` (cheap SKU)

-- 1. Required extensions. Idempotent — Supabase usually has postgis already
-- enabled on the `extensions` schema, but the IF NOT EXISTS keeps this
-- migration safe against fresh clones.
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- 2. Augment city_places with a generated geography column so the Edge
-- Function can use ST_DWithin without round-tripping through ad-hoc
-- ST_MakePoint() calls in every query. Trigram index on name powers the
-- fuzzy match.
ALTER TABLE public.city_places
  ADD COLUMN IF NOT EXISTS geom geography(Point, 4326)
  GENERATED ALWAYS AS (ST_SetSRID(ST_MakePoint(lng, lat), 4326)::geography) STORED;

CREATE INDEX IF NOT EXISTS city_places_geom_gix
  ON public.city_places USING GIST (geom);

CREATE INDEX IF NOT EXISTS city_places_name_trgm
  ON public.city_places USING GIN (name gin_trgm_ops);

COMMENT ON COLUMN public.city_places.geom IS
  'Generated PostGIS geography for spatial proximity queries. '
  'Required by lookup-place-id Edge Function (Phase C of places-cost plan).';

-- 3. Bridge cache table. NO unique key — multiple Apple-side names can
-- legitimately resolve to the same Google place_id (e.g. "Café Fleur" vs
-- "Cafe Fleur") and we keep them all so future fuzzy matches benefit.
CREATE TABLE IF NOT EXISTS public.place_id_bridge (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  -- Original Apple/MapKit query inputs.
  lat double precision NOT NULL,
  lng double precision NOT NULL,
  geom geography(Point, 4326)
    GENERATED ALWAYS AS (ST_SetSRID(ST_MakePoint(lng, lat), 4326)::geography) STORED,
  name text NOT NULL,
  -- Resolved Google place_id.
  place_id text NOT NULL,
  -- Provenance of the row, drives cache hit attribution.
  source text NOT NULL CHECK (source IN ('city_places', 'google_text_search', 'manual')),
  -- 0.0 – 1.0 confidence the Edge Function had at write time. 0.85+ auto-
  -- accepts on read; anything lower returns ambiguous candidates to iOS.
  confidence numeric(3, 2) NOT NULL CHECK (confidence >= 0 AND confidence <= 1),
  -- Optional city scoping — when known, lets us prefer same-city resolutions
  -- over distant homonyms.
  city_profile_id uuid REFERENCES public.city_profiles (id) ON DELETE SET NULL,
  resolved_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS place_id_bridge_geom_gix
  ON public.place_id_bridge USING GIST (geom);

CREATE INDEX IF NOT EXISTS place_id_bridge_name_trgm
  ON public.place_id_bridge USING GIN (name gin_trgm_ops);

CREATE INDEX IF NOT EXISTS place_id_bridge_place_id_idx
  ON public.place_id_bridge (place_id);

CREATE INDEX IF NOT EXISTS place_id_bridge_city_profile_idx
  ON public.place_id_bridge (city_profile_id)
  WHERE city_profile_id IS NOT NULL;

COMMENT ON TABLE public.place_id_bridge IS
  'Apple MapKit (lat/lng/name) → Google place_id resolution cache. '
  'Populated by the lookup-place-id Edge Function on miss. '
  'Multiple rows may share a place_id (different name spellings).';

-- 4. RLS — read public so Edge Functions on anon claims can probe; writes
-- only via service_role from inside the lookup-place-id function.
ALTER TABLE public.place_id_bridge ENABLE ROW LEVEL SECURITY;

CREATE POLICY place_id_bridge_public_read ON public.place_id_bridge
  FOR SELECT USING (true);

GRANT SELECT ON public.place_id_bridge TO anon, authenticated;

-- 5. RPC helpers used by the lookup-place-id Edge Function. SECURITY
-- DEFINER so anon JWTs can call them through PostgREST without needing
-- service-role from the function. They only do read-only spatial queries.

CREATE OR REPLACE FUNCTION public.lookup_place_id_city_places(
  p_lat double precision,
  p_lng double precision,
  p_name text,
  p_radius_m double precision DEFAULT 250,
  p_limit integer DEFAULT 5
)
RETURNS TABLE (
  place_id text,
  name text,
  lat double precision,
  lng double precision,
  distance_m double precision,
  name_sim real
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH probe AS (
    SELECT ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography AS g
  )
  SELECT
    cp.place_id,
    cp.name,
    cp.lat,
    cp.lng,
    ST_Distance(cp.geom, probe.g) AS distance_m,
    similarity(cp.name, p_name) AS name_sim
  FROM public.city_places cp
  CROSS JOIN probe
  WHERE cp.status = 'active'
    AND ST_DWithin(cp.geom, probe.g, p_radius_m)
  ORDER BY ST_Distance(cp.geom, probe.g) ASC
  LIMIT p_limit;
$$;

GRANT EXECUTE ON FUNCTION public.lookup_place_id_city_places(
  double precision, double precision, text, double precision, integer
) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.lookup_place_id_bridge(
  p_lat double precision,
  p_lng double precision,
  p_name text,
  p_radius_m double precision DEFAULT 250,
  p_limit integer DEFAULT 5
)
RETURNS TABLE (
  place_id text,
  name text,
  lat double precision,
  lng double precision,
  distance_m double precision,
  name_sim real
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH probe AS (
    SELECT ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography AS g
  )
  SELECT
    b.place_id,
    b.name,
    b.lat,
    b.lng,
    ST_Distance(b.geom, probe.g) AS distance_m,
    similarity(b.name, p_name) AS name_sim
  FROM public.place_id_bridge b
  CROSS JOIN probe
  WHERE ST_DWithin(b.geom, probe.g, p_radius_m)
  ORDER BY ST_Distance(b.geom, probe.g) ASC
  LIMIT p_limit;
$$;

GRANT EXECUTE ON FUNCTION public.lookup_place_id_bridge(
  double precision, double precision, text, double precision, integer
) TO authenticated, service_role;
