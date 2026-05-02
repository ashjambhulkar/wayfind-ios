-- Rich place details, AI blurbs, contact fields, and images for city_places pool rows.

ALTER TABLE public.city_places
  ADD COLUMN IF NOT EXISTS rating double precision,
  ADD COLUMN IF NOT EXISTS user_ratings_total integer,
  ADD COLUMN IF NOT EXISTS price_level integer,
  ADD COLUMN IF NOT EXISTS opening_hours jsonb,
  ADD COLUMN IF NOT EXISTS details_enriched_at timestamptz,

  ADD COLUMN IF NOT EXISTS ai_editorial_summary text,
  ADD COLUMN IF NOT EXISTS ai_review_summary text,
  ADD COLUMN IF NOT EXISTS ai_why_go text[],
  ADD COLUMN IF NOT EXISTS ai_know_before_you_go text[],
  ADD COLUMN IF NOT EXISTS ai_enriched_at timestamptz,

  ADD COLUMN IF NOT EXISTS formatted_phone_number text,
  ADD COLUMN IF NOT EXISTS international_phone_number text,
  ADD COLUMN IF NOT EXISTS website text,
  ADD COLUMN IF NOT EXISTS images jsonb;

COMMENT ON COLUMN public.city_places.details_enriched_at IS
  'When structured place details (rating, hours, phones, etc.) were last enriched.';

COMMENT ON COLUMN public.city_places.ai_enriched_at IS
  'When AI summary fields were last successfully written.';

COMMENT ON COLUMN public.city_places.images IS
  'Image metadata for the place (e.g. JSON array of photo URLs or Google-style photo objects).';
