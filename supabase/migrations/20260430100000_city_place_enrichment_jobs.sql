-- Queue for city_place_enricher Edge Function: enqueue on insert/update, claim via RPC (SKIP LOCKED).

-- Queue table
CREATE TABLE IF NOT EXISTS public.city_place_enrichment_jobs (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  city_place_id uuid NOT NULL REFERENCES public.city_places (id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'processing', 'done', 'failed')),
  attempts integer NOT NULL DEFAULT 0,
  last_error text NULL,
  run_after timestamptz NOT NULL DEFAULT now(),
  locked_at timestamptz NULL,
  started_at timestamptz NULL,
  finished_at timestamptz NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (city_place_id)
);

CREATE INDEX IF NOT EXISTS city_place_enrichment_jobs_status_run_after_idx
  ON public.city_place_enrichment_jobs (status, run_after, created_at);

CREATE INDEX IF NOT EXISTS city_place_enrichment_jobs_city_place_id_idx
  ON public.city_place_enrichment_jobs (city_place_id);

CREATE OR REPLACE FUNCTION public.set_updated_at_city_place_enrichment_jobs()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_city_place_enrichment_jobs_updated_at ON public.city_place_enrichment_jobs;
CREATE TRIGGER trg_city_place_enrichment_jobs_updated_at
BEFORE UPDATE ON public.city_place_enrichment_jobs
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at_city_place_enrichment_jobs();

-- Enqueue on INSERT
CREATE OR REPLACE FUNCTION public.enqueue_city_place_enrichment()
RETURNS trigger
LANGUAGE plpgsql
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

DROP TRIGGER IF EXISTS trg_enqueue_city_place_enrichment ON public.city_places;
CREATE TRIGGER trg_enqueue_city_place_enrichment
AFTER INSERT ON public.city_places
FOR EACH ROW
EXECUTE FUNCTION public.enqueue_city_place_enrichment();

-- Optional: re-enqueue if place_id changes or row is reset
CREATE OR REPLACE FUNCTION public.reenqueue_city_place_enrichment_on_update()
RETURNS trigger
LANGUAGE plpgsql
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

DROP TRIGGER IF EXISTS trg_reenqueue_city_place_enrichment ON public.city_places;
CREATE TRIGGER trg_reenqueue_city_place_enrichment
AFTER UPDATE ON public.city_places
FOR EACH ROW
EXECUTE FUNCTION public.reenqueue_city_place_enrichment_on_update();

-- Atomic claim function using SKIP LOCKED
CREATE OR REPLACE FUNCTION public.claim_city_place_enrichment_jobs(batch_size integer DEFAULT 5)
RETURNS SETOF public.city_place_enrichment_jobs
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  WITH picked AS (
    SELECT j.id
    FROM public.city_place_enrichment_jobs j
    WHERE j.status IN ('pending', 'failed')
      AND j.run_after <= now()
      AND j.attempts < 8
    ORDER BY j.created_at ASC
    LIMIT batch_size
    FOR UPDATE SKIP LOCKED
  )
  UPDATE public.city_place_enrichment_jobs j
  SET status = 'processing',
      attempts = j.attempts + 1,
      locked_at = now(),
      started_at = now(),
      updated_at = now()
  FROM picked
  WHERE j.id = picked.id
  RETURNING j.*;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_city_place_enrichment_jobs(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.claim_city_place_enrichment_jobs(integer) TO service_role;
