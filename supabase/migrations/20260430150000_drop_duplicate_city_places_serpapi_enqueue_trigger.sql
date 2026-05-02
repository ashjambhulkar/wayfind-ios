-- Duplicate AFTER INSERT triggers both called pgmq.send('city_places_serpapi', ...).
-- Kept: trg_enqueue_city_place_for_serpapi / enqueue_city_place_for_serpapi (clearer name).
DROP TRIGGER IF EXISTS trg_enqueue_city_place_serpapi_job ON public.city_places;
DROP FUNCTION IF EXISTS public.enqueue_city_place_serpapi_job();
