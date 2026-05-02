-- Phase G.2 (places-cost-and-owned-data plan).
--
-- Builds on top of `public.feature_flags` (created in
-- 20260601140000_feature_flags.sql). Adds the runtime kill-switches
-- + provider toggles the iOS client polls every hour. The schema
-- itself stays unchanged; we only seed rows + add string/bool
-- accessor RPCs so the client doesn't have to teach itself JSONB.
--
-- Flag glossary
-- -------------
-- * flag_map_search_provider          (string)
--     What the trip-map "Add place" search uses.
--       'apple'          → MKLocalSearchCompleter (default, free)
--       'google'         → PlaceSearchService autocomplete (paid fallback)
--       'china_fallback' → Apple in mainland China replaced with Google
--                          Place Details + autocomplete (Apple sparse there)
-- * flag_stay_area_autocomplete_api   (string)
--     Which Google endpoint the AI stay-area picker hits.
--       'new'    → Places API (New) `/v1/places:autocomplete` (default)
--       'legacy' → `/maps/api/place/autocomplete/json`
--     Lets us roll back instantly if the New API regresses without a
--     binary release.
-- * flag_user_photos                  (bool)
--     Master kill-switch for Phase F. Disables BOTH the upload UI
--     and the carousel rendering of approved photos so we can
--     mute moderation pipeline if a CSAM scanner outage spikes.

-- ---------------------------------------------------------------
-- Seed rows. Idempotent — existing values are preserved on re-run.
-- ---------------------------------------------------------------

INSERT INTO public.feature_flags (flag, value, description) VALUES
  ('flag_map_search_provider',
   '"china_fallback"'::jsonb,
   'Trip-map search provider. Allowed: "apple" (always free MapKit), "google" (force-Google emergency fallback), "china_fallback" (default — Apple worldwide except inside mainland China''s bounding box, where MapKit returns sparse data). 1h client cache.'),
  ('flag_stay_area_autocomplete_api',
   '"new"'::jsonb,
   'Which Google autocomplete endpoint the AI stay-area picker uses. Allowed: "new" (Places API New, default), "legacy". 1h client cache.'),
  ('flag_user_photos',
   'true'::jsonb,
   'Master kill-switch for Phase F user-uploaded photos. false hides the upload UI and stops rendering approved user photos in the carousel. 1h client cache.')
ON CONFLICT (flag) DO NOTHING;

-- ---------------------------------------------------------------
-- Accessor RPCs (string + bool). int variant already exists.
-- ---------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.feature_flag_text(
  p_flag text,
  p_default text
)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    (SELECT value #>> '{}' FROM public.feature_flags WHERE flag = p_flag),
    p_default
  );
$$;

CREATE OR REPLACE FUNCTION public.feature_flag_bool(
  p_flag text,
  p_default boolean
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    (SELECT (value)::text::boolean FROM public.feature_flags WHERE flag = p_flag),
    p_default
  );
$$;

GRANT EXECUTE ON FUNCTION public.feature_flag_text(text, text)
  TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.feature_flag_bool(text, boolean)
  TO anon, authenticated, service_role;
