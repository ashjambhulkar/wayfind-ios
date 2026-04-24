-- Enable RLS on internal queue table (Supabase advisor: public schema + PostgREST).
-- Direct client access denied; service_role (Edge) bypasses RLS.
-- Enqueue triggers use SECURITY DEFINER so INSERT into jobs is not blocked for invoker roles.

ALTER TABLE public.city_place_enrichment_jobs ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.city_place_enrichment_jobs FROM PUBLIC;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.city_place_enrichment_jobs TO service_role;

CREATE OR REPLACE FUNCTION public.enqueue_city_place_enrichment()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.status IN ('active', 'reported') THEN
    INSERT INTO public.city_place_enrichment_jobs (city_place_id, status, run_after)
    VALUES (NEW.id, 'pending', now())
    ON CONFLICT (city_place_id) DO UPDATE
      SET status = CASE
        WHEN public.city_place_enrichment_jobs.status = 'done' THEN 'pending'
        ELSE public.city_place_enrichment_jobs.status
      END,
          run_after = now(),
          last_error = NULL,
          finished_at = NULL,
          updated_at = now();
  END IF;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.reenqueue_city_place_enrichment_on_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.status IN ('active', 'reported')
     AND (
       OLD.place_id IS DISTINCT FROM NEW.place_id
       OR OLD.details_enriched_at IS DISTINCT FROM NEW.details_enriched_at
       OR OLD.ai_enriched_at IS DISTINCT FROM NEW.ai_enriched_at
     ) THEN
    INSERT INTO public.city_place_enrichment_jobs (city_place_id, status, run_after)
    VALUES (NEW.id, 'pending', now())
    ON CONFLICT (city_place_id) DO UPDATE
      SET status = 'pending',
          run_after = now(),
          last_error = NULL,
          finished_at = NULL,
          updated_at = now();
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON TABLE public.city_place_enrichment_jobs IS
  'Internal worker queue for city-place-enricher. RLS enabled; use service_role or claim RPC.';
