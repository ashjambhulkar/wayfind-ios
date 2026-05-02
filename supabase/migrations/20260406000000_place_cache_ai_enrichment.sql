-- AI-generated rich content for place detail screens.
-- All columns are nullable; missing = not yet enriched (or enrichment failed).

ALTER TABLE public.place_cache
  ADD COLUMN IF NOT EXISTS ai_editorial_summary   text         NULL,
  ADD COLUMN IF NOT EXISTS ai_review_summary      text         NULL,
  ADD COLUMN IF NOT EXISTS ai_why_go              text[]       NULL,
  ADD COLUMN IF NOT EXISTS ai_know_before_you_go  text[]       NULL,
  ADD COLUMN IF NOT EXISTS ai_enriched_at         timestamptz  NULL;
