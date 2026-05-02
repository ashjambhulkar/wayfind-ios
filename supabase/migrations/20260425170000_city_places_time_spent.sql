-- Google-style dwell time ranges (scraped / offline enrichment) for TTDP visit duration.

ALTER TABLE public.city_places
  ADD COLUMN IF NOT EXISTS time_spent_min integer,
  ADD COLUMN IF NOT EXISTS time_spent_max integer,
  ADD COLUMN IF NOT EXISTS time_spent_enriched_at timestamptz;

COMMENT ON COLUMN public.city_places.time_spent_min IS
  'Minimum typical visit length in minutes (e.g. from Google Maps dwell hints).';

COMMENT ON COLUMN public.city_places.time_spent_max IS
  'Maximum typical visit length in minutes (paired with time_spent_min).';

COMMENT ON COLUMN public.city_places.time_spent_enriched_at IS
  'When dwell-time enrichment was last attempted (success, no data, or failure). NULL = not yet processed.';

CREATE INDEX IF NOT EXISTS idx_city_places_time_spent_queue
  ON public.city_places (city_profile_id)
  WHERE time_spent_enriched_at IS NULL;
