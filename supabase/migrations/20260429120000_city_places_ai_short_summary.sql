-- One-line teaser for compact UI (lists, chips); optional until backfilled.

ALTER TABLE public.city_places
  ADD COLUMN IF NOT EXISTS ai_short_summary text;

COMMENT ON COLUMN public.city_places.ai_short_summary IS
  'Very short grounded hook (typically one sentence) for summaries; null until enriched.';
