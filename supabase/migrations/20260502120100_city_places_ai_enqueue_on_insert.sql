-- OpenAI enrichment (city_places_ai queue) is decoupled from Serp:
-- new active rows enqueue immediately so ai-consumer does not wait for Serp.
-- serp-consumer may still enqueue after a successful Serp update so ai-consumer
-- can refresh copy when details_enriched_at advances past ai_enriched_at.

CREATE OR REPLACE FUNCTION public.enqueue_city_place_for_ai()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Match ai-consumer: only active / reported (treat NULL like consumer's ?? '')
  IF COALESCE(NEW.status, '') NOT IN ('active', 'reported') THEN
    RETURN NEW;
  END IF;

  PERFORM pgmq_public.send(
    'city_places_ai',
    jsonb_build_object('city_place_id', NEW.id::text),
    0
  );
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enqueue_city_place_for_ai ON public.city_places;
CREATE TRIGGER trg_enqueue_city_place_for_ai
  AFTER INSERT ON public.city_places
  FOR EACH ROW
  EXECUTE FUNCTION public.enqueue_city_place_for_ai();

COMMENT ON FUNCTION public.enqueue_city_place_for_ai() IS
  'PGMQ send to city_places_ai on insert so OpenAI can run in parallel with Serp.';
