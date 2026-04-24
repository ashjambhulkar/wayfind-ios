-- Optional review-derived tag labels (e.g. themes from aggregated reviews) for pool rows.

ALTER TABLE public.city_places
  ADD COLUMN IF NOT EXISTS reviews_tags text[] DEFAULT '{}';

COMMENT ON COLUMN public.city_places.reviews_tags IS
  'Short tag strings derived from or summarizing review themes for this place; empty if unknown.';
