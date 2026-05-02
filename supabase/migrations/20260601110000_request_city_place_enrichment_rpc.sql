-- Phase D.2 — Foreground enrichment request RPC.
--
-- The Place Detail sheet calls this on .task to ensure the underlying
-- city_places row gets enriched (rating, hours, AI summaries, …) within
-- seconds of the user opening it. Without this, sheet-open jobs would queue
-- behind background backfills and the user would stare at empty fields.
--
-- Stampede protection: if a `pending` or `processing` job already exists for
-- the city_place, the RPC is a no-op (returns the existing row). This means
-- 100 simultaneous viewers of the same place all share one Google fetch.
--
-- Priority lane: `foreground` jobs are sorted ahead of `background` jobs in
-- the worker claim function, so the sheet user gets first dibs on the worker
-- pool.

-- 1. Add priority column to the queue. `background` is the existing default
-- behavior so we don't disturb in-flight backfills.
ALTER TABLE public.city_place_enrichment_jobs
  ADD COLUMN IF NOT EXISTS priority text NOT NULL DEFAULT 'background'
  CHECK (priority IN ('foreground', 'background'));

CREATE INDEX IF NOT EXISTS city_place_enrichment_jobs_priority_idx
  ON public.city_place_enrichment_jobs (priority, run_after, created_at)
  WHERE status IN ('pending', 'failed');

-- 2. Update the SKIP LOCKED claim function to honour priority. We sort by
-- (priority='foreground' DESC, run_after, created_at) so foreground jobs
-- with the same run_after cut to the front of the queue.
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
    ORDER BY (j.priority = 'foreground') DESC, j.run_after ASC, j.created_at ASC
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

-- 3. The actual client-facing RPC. Returns the (existing or newly inserted)
-- job row so the iOS client can subscribe to its status via Realtime if it
-- wants. SECURITY DEFINER because authenticated users wouldn't otherwise be
-- allowed to write to `city_place_enrichment_jobs`.
CREATE OR REPLACE FUNCTION public.request_city_place_enrichment(
  p_city_place_id uuid,
  p_priority text DEFAULT 'foreground'
)
RETURNS public.city_place_enrichment_jobs
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_priority text := COALESCE(p_priority, 'foreground');
  v_row public.city_place_enrichment_jobs%ROWTYPE;
BEGIN
  IF v_priority NOT IN ('foreground', 'background') THEN
    RAISE EXCEPTION 'invalid priority: %', v_priority USING ERRCODE = '22023';
  END IF;

  -- Verify the city_place exists and is visible — otherwise we'd silently
  -- enqueue ghosts. RLS on city_places is public-read, so an authenticated
  -- session can always probe this.
  PERFORM 1 FROM public.city_places WHERE id = p_city_place_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'city_place not found: %', p_city_place_id USING ERRCODE = 'P0002';
  END IF;

  -- Stampede dedupe: ON CONFLICT (city_place_id) — we only ever have one
  -- row per city_place. The CASE keeps in-flight `processing` rows alone,
  -- promotes `done` rows back to `pending` (lazy refresh), and bumps
  -- priority to foreground if a background job was already queued.
  INSERT INTO public.city_place_enrichment_jobs (city_place_id, status, priority, run_after)
  VALUES (p_city_place_id, 'pending', v_priority, now())
  ON CONFLICT (city_place_id) DO UPDATE
    SET status = CASE
          WHEN public.city_place_enrichment_jobs.status = 'done' THEN 'pending'
          WHEN public.city_place_enrichment_jobs.status = 'processing' THEN 'processing'
          ELSE 'pending'
        END,
        priority = CASE
          WHEN v_priority = 'foreground' THEN 'foreground'
          ELSE public.city_place_enrichment_jobs.priority
        END,
        run_after = LEAST(public.city_place_enrichment_jobs.run_after, now()),
        last_error = NULL,
        finished_at = NULL,
        updated_at = now()
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

REVOKE ALL ON FUNCTION public.request_city_place_enrichment(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.request_city_place_enrichment(uuid, text)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.request_city_place_enrichment(uuid, text) IS
  'Phase D.2: foreground (sheet-open) or background enrichment request. '
  'Safe to call from clients — stampede-deduped via the (city_place_id) unique key.';
