-- Phase I.1 — Track open-data attribution.
--
-- We're about to start mixing open-data (Wikidata, Wikivoyage, Overpass)
-- into `city_places` AI summaries. CC-BY-SA + the EU DSA both demand we
-- record (and ultimately surface) which sources fed each row. This
-- column is the audit log that the rendering layer reads to assemble
-- per-place attribution captions.
--
-- Shape:
--   {
--     "summary":       { "sources": ["wikipedia:en:Eiffel_Tower#rev=12345", "wikivoyage:en:Paris#rev=678"] },
--     "why_go":        { "sources": ["openai:gpt-4o-2026-01-15"] },
--     "thumbnail":     { "sources": ["wikimedia:File:Tour_Eiffel_2024.jpg", "license": "CC BY-SA 4.0"] }
--   }
--
-- We treat this as opaque JSON in SQL and let the Edge Function /
-- ingest jobs own the structure.

ALTER TABLE public.city_places
  ADD COLUMN IF NOT EXISTS ai_source_attribution jsonb;

COMMENT ON COLUMN public.city_places.ai_source_attribution IS
  'Per-field attribution for CC license + DSA compliance. Keys mirror '
  'enrichment field names (summary, why_go, know_before_you_go, '
  'thumbnail, etc). See Phase I.1 of the places-cost-and-owned-data plan.';

-- Lightweight read index for the Edge Function that periodically scans
-- for rows missing attribution on enriched fields. Partial so we only
-- pay for rows that need backfill.
CREATE INDEX IF NOT EXISTS city_places_missing_attribution_idx
  ON public.city_places (id)
  WHERE ai_editorial_summary IS NOT NULL AND ai_source_attribution IS NULL;
