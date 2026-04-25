-- Phase H.1 — Image source provenance + refresh-cycle tracking on city_places.
--
-- Why split image refresh from data refresh:
--   • Photos cost more per refresh than text fields (Google `places.photos`
--     SKU is the most expensive Place Details bit; SerpAPI is even worse).
--   • Photos go stale slower than data (a restaurant changes hours every
--     few months, but its hero photo stays useful for years).
--   • User-contributed photos (Phase F) NEVER refresh from a third party;
--     `image_source = 'user'` is a hard stop for the lazy refresh RPC.

ALTER TABLE public.city_places
  ADD COLUMN IF NOT EXISTS image_source text
    CHECK (image_source IN ('google', 'serpapi', 'wikimedia', 'user', 'unknown'))
    DEFAULT 'unknown',
  ADD COLUMN IF NOT EXISTS images_refreshed_at timestamptz,
  ADD COLUMN IF NOT EXISTS thumbnail_attribution text;

-- Backfill: every existing thumbnail came from SerpAPI's image search before
-- this plan, so mark it appropriately. After this, new images written by
-- the city-place-enricher will set image_source explicitly.
UPDATE public.city_places
   SET image_source = 'serpapi',
       images_refreshed_at = COALESCE(images_refreshed_at, last_refreshed_at)
 WHERE image_source = 'unknown'
   AND thumbnail_url IS NOT NULL;

COMMENT ON COLUMN public.city_places.image_source IS
  'Provenance of thumbnail_url: google (Place Photos), serpapi (legacy), '
  'wikimedia (Wikidata/Commons via Phase I), user (approved user upload via Phase F), '
  'unknown (no image yet). Drives refresh policy and attribution caption.';

COMMENT ON COLUMN public.city_places.images_refreshed_at IS
  'Last time images were refreshed. Independent from details_enriched_at because '
  'images TTL is much longer than text TTL (see feature_flags city_places_image_ttl_days).';

COMMENT ON COLUMN public.city_places.thumbnail_attribution IS
  'Required attribution string for the current thumbnail (e.g. CC license + author). '
  'Rendered in the Place Detail attribution footer (Phase I.3).';

-- Index used by refresh_city_place_if_stale to find candidates fast.
CREATE INDEX IF NOT EXISTS city_places_images_refresh_idx
  ON public.city_places (images_refreshed_at)
  WHERE status = 'active' AND image_source <> 'user';
