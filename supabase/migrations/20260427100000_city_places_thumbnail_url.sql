-- Optional explicit thumbnail per pool row. When null, Edge/app uses first URL from `images` at read time (no backfill).

ALTER TABLE public.city_places
  ADD COLUMN IF NOT EXISTS thumbnail_url text NULL;

COMMENT ON COLUMN public.city_places.thumbnail_url IS
  'Optional explicit thumbnail URL for UI. If null, derive from the first entry in `images` jsonb in application code — not stored here.';
