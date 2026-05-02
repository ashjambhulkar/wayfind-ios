-- Structured review summary payload for UI; optional until enriched.

ALTER TABLE public.city_places
  ADD COLUMN IF NOT EXISTS reviews_summary_json jsonb,
  ADD COLUMN IF NOT EXISTS reviews_summary_enriched_at timestamptz;

COMMENT ON COLUMN public.city_places.reviews_summary_json IS
  'JSON summary of reviews (themes, highlights); null until enriched.';

COMMENT ON COLUMN public.city_places.reviews_summary_enriched_at IS
  'When reviews_summary_json was last written; null if never enriched.';
