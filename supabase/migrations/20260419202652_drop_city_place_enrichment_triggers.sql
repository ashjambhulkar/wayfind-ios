-- Remove city_place_enrichment_jobs enqueue triggers (SerpApi/AI PGMQ pipeline is separate).
DROP TRIGGER IF EXISTS trg_enqueue_city_place_enrichment ON public.city_places;
DROP TRIGGER IF EXISTS trg_reenqueue_city_place_enrichment ON public.city_places;
