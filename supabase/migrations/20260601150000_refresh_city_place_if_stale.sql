-- Phase H.3 — Lazy refresh RPC for city_places.
--
-- Reads TTL from feature_flags (city_places_data_ttl_days /
-- city_places_image_ttl_days), then enqueues a *focused* enrichment job
-- with mode='details' or mode='images' so the worker only does the work
-- that's actually stale.
--
-- Critical invariant: when image_source = 'user', NEVER overwrite the
-- thumbnail. User-contributed photos (Phase F) are sacred — they go
-- through their own moderation and lifecycle.
--
-- This RPC is called by the iOS app on .task in the Place Detail sheet,
-- and by background workers walking the active city_places set.

-- 1. Add `mode` column to the enrichment job queue. Existing rows default
-- to 'all' (back-compat with the original behavior).
ALTER TABLE public.city_place_enrichment_jobs
  ADD COLUMN IF NOT EXISTS mode text NOT NULL DEFAULT 'all'
  CHECK (mode IN ('details', 'images', 'all'));

CREATE INDEX IF NOT EXISTS city_place_enrichment_jobs_mode_idx
  ON public.city_place_enrichment_jobs (mode)
  WHERE status IN ('pending', 'failed');

-- 2. The lazy refresh RPC. Returns the number of jobs enqueued (0, 1, or 2)
-- so the caller can debug/log without re-querying.
CREATE OR REPLACE FUNCTION public.refresh_city_place_if_stale(
  p_city_place_id uuid,
  p_priority text DEFAULT 'background'
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_priority text := COALESCE(p_priority, 'background');
  v_data_ttl_days integer := public.feature_flag_int('city_places_data_ttl_days', 180);
  v_image_ttl_days integer := public.feature_flag_int('city_places_image_ttl_days', 180);
  v_data_cutoff timestamptz := now() - make_interval(days => v_data_ttl_days);
  v_image_cutoff timestamptz := now() - make_interval(days => v_image_ttl_days);
  v_row public.city_places%ROWTYPE;
  v_jobs_enqueued integer := 0;
  v_data_stale boolean;
  v_images_stale boolean;
BEGIN
  IF v_priority NOT IN ('foreground', 'background') THEN
    RAISE EXCEPTION 'invalid priority: %', v_priority USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_row FROM public.city_places WHERE id = p_city_place_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'city_place not found: %', p_city_place_id USING ERRCODE = 'P0002';
  END IF;

  v_data_stale := v_row.details_enriched_at IS NULL OR v_row.details_enriched_at < v_data_cutoff;
  -- Images are stale iff our image source is refreshable AND the
  -- last-refresh timestamp is older than the image TTL. User photos
  -- are excluded — they own the slot until removed by the Phase F
  -- lifecycle, never by lazy refresh.
  v_images_stale :=
    v_row.image_source <> 'user'
    AND (v_row.images_refreshed_at IS NULL OR v_row.images_refreshed_at < v_image_cutoff);

  IF v_data_stale THEN
    INSERT INTO public.city_place_enrichment_jobs
      (city_place_id, status, priority, mode, run_after)
    VALUES (p_city_place_id, 'pending', v_priority, 'details', now())
    ON CONFLICT (city_place_id) DO UPDATE
      SET status = CASE
            WHEN public.city_place_enrichment_jobs.status = 'processing' THEN 'processing'
            ELSE 'pending'
          END,
          priority = CASE
            WHEN v_priority = 'foreground' THEN 'foreground'
            ELSE public.city_place_enrichment_jobs.priority
          END,
          mode = CASE
            -- If both details and images were stale, the second insert
            -- below will widen the mode to 'all'.
            WHEN public.city_place_enrichment_jobs.mode = 'images' THEN 'all'
            ELSE 'details'
          END,
          run_after = LEAST(public.city_place_enrichment_jobs.run_after, now()),
          last_error = NULL,
          finished_at = NULL,
          updated_at = now();
    v_jobs_enqueued := v_jobs_enqueued + 1;
  END IF;

  IF v_images_stale THEN
    INSERT INTO public.city_place_enrichment_jobs
      (city_place_id, status, priority, mode, run_after)
    VALUES (p_city_place_id, 'pending', v_priority, 'images', now())
    ON CONFLICT (city_place_id) DO UPDATE
      SET status = CASE
            WHEN public.city_place_enrichment_jobs.status = 'processing' THEN 'processing'
            ELSE 'pending'
          END,
          priority = CASE
            WHEN v_priority = 'foreground' THEN 'foreground'
            ELSE public.city_place_enrichment_jobs.priority
          END,
          mode = CASE
            WHEN public.city_place_enrichment_jobs.mode = 'details' THEN 'all'
            ELSE 'images'
          END,
          run_after = LEAST(public.city_place_enrichment_jobs.run_after, now()),
          last_error = NULL,
          finished_at = NULL,
          updated_at = now();
    v_jobs_enqueued := v_jobs_enqueued + 1;
  END IF;

  RETURN v_jobs_enqueued;
END;
$$;

REVOKE ALL ON FUNCTION public.refresh_city_place_if_stale(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.refresh_city_place_if_stale(uuid, text)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.refresh_city_place_if_stale(uuid, text) IS
  'Phase H.3: TTL-driven lazy refresh. Splits details vs images jobs so '
  'expensive image refreshes only happen on the image TTL cycle.';
