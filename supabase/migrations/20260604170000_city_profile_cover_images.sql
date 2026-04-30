-- City cover image pools.
--
-- Caches a small Unsplash-backed cover pool per city_profiles row so trip
-- creation can rotate local images without calling Unsplash on the hot path.

CREATE TABLE IF NOT EXISTS public.city_profile_cover_images (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  city_profile_id uuid NOT NULL REFERENCES public.city_profiles (id) ON DELETE CASCADE,
  source text NOT NULL DEFAULT 'unsplash' CHECK (source IN ('unsplash')),
  source_photo_id text NOT NULL,
  image_url text NOT NULL,
  image_width integer,
  image_height integer,
  photographer_name text,
  photographer_username text,
  photographer_url text,
  photo_page_url text,
  download_location text,
  attribution jsonb NOT NULL DEFAULT '{}'::jsonb,
  position integer NOT NULL DEFAULT 0,
  is_active boolean NOT NULL DEFAULT true,
  fetched_at timestamptz NOT NULL DEFAULT now(),
  last_assigned_at timestamptz,
  assignment_count integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (city_profile_id, source, source_photo_id)
);

CREATE INDEX IF NOT EXISTS city_profile_cover_images_pick_idx
  ON public.city_profile_cover_images (
    city_profile_id,
    is_active,
    assignment_count,
    last_assigned_at NULLS FIRST
  );

CREATE INDEX IF NOT EXISTS city_profile_cover_images_city_idx
  ON public.city_profile_cover_images (city_profile_id, position);

COMMENT ON TABLE public.city_profile_cover_images IS
  'Cached Unsplash cover image pool per city profile. Trips rotate through this local pool instead of searching Unsplash.';

CREATE TABLE IF NOT EXISTS public.city_profile_cover_fetch_jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  city_profile_id uuid NOT NULL REFERENCES public.city_profiles (id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'processing', 'done', 'failed')),
  attempts integer NOT NULL DEFAULT 0,
  last_error text,
  run_after timestamptz NOT NULL DEFAULT now(),
  locked_at timestamptz,
  started_at timestamptz,
  finished_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS city_profile_cover_fetch_jobs_active_unique
  ON public.city_profile_cover_fetch_jobs (city_profile_id)
  WHERE status IN ('pending', 'processing');

CREATE INDEX IF NOT EXISTS city_profile_cover_fetch_jobs_claim_idx
  ON public.city_profile_cover_fetch_jobs (status, run_after, created_at);

COMMENT ON TABLE public.city_profile_cover_fetch_jobs IS
  'Internal queue for server-side Unsplash city cover pool fetches. One active job per city profile.';

CREATE TABLE IF NOT EXISTS public.external_api_usage_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider text NOT NULL,
  endpoint text NOT NULL,
  city_profile_id uuid REFERENCES public.city_profiles (id) ON DELETE SET NULL,
  request_count integer NOT NULL DEFAULT 1 CHECK (request_count > 0),
  status text NOT NULL DEFAULT 'success',
  meta jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS external_api_usage_events_quota_idx
  ON public.external_api_usage_events (provider, endpoint, created_at);

COMMENT ON TABLE public.external_api_usage_events IS
  'Service-role-only external API ledger used for quota enforcement and audit, including Unsplash cover pool calls.';

CREATE TABLE IF NOT EXISTS public.city_profile_cover_assignments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  city_profile_id uuid NOT NULL REFERENCES public.city_profiles (id) ON DELETE CASCADE,
  cover_image_id uuid NOT NULL REFERENCES public.city_profile_cover_images (id) ON DELETE CASCADE,
  trip_id uuid REFERENCES public.trips (id) ON DELETE CASCADE,
  assigned_to_user_id uuid,
  download_location text,
  download_tracked_at timestamptz,
  download_track_attempts integer NOT NULL DEFAULT 0,
  download_track_last_error text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS city_profile_cover_assignments_tracking_idx
  ON public.city_profile_cover_assignments (download_tracked_at, download_track_attempts, created_at)
  WHERE download_location IS NOT NULL AND download_tracked_at IS NULL;

CREATE INDEX IF NOT EXISTS city_profile_cover_assignments_trip_idx
  ON public.city_profile_cover_assignments (trip_id)
  WHERE trip_id IS NOT NULL;

COMMENT ON TABLE public.city_profile_cover_assignments IS
  'Audit trail for city cover selections. The worker uses it to send Unsplash download tracking calls.';

CREATE OR REPLACE FUNCTION public.set_updated_at_city_profile_cover_images()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_city_profile_cover_images_updated_at ON public.city_profile_cover_images;
CREATE TRIGGER trg_city_profile_cover_images_updated_at
BEFORE UPDATE ON public.city_profile_cover_images
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at_city_profile_cover_images();

CREATE OR REPLACE FUNCTION public.set_updated_at_city_profile_cover_fetch_jobs()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_city_profile_cover_fetch_jobs_updated_at ON public.city_profile_cover_fetch_jobs;
CREATE TRIGGER trg_city_profile_cover_fetch_jobs_updated_at
BEFORE UPDATE ON public.city_profile_cover_fetch_jobs
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at_city_profile_cover_fetch_jobs();

ALTER TABLE public.city_profile_cover_images ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.city_profile_cover_fetch_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.external_api_usage_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.city_profile_cover_assignments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS city_profile_cover_images_public_read ON public.city_profile_cover_images;
CREATE POLICY city_profile_cover_images_public_read
  ON public.city_profile_cover_images
  FOR SELECT
  USING (is_active = true);

REVOKE ALL ON TABLE public.city_profile_cover_fetch_jobs FROM PUBLIC;
REVOKE ALL ON TABLE public.external_api_usage_events FROM PUBLIC;
REVOKE ALL ON TABLE public.city_profile_cover_assignments FROM PUBLIC;

GRANT SELECT ON public.city_profile_cover_images TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.city_profile_cover_images TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.city_profile_cover_fetch_jobs TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.external_api_usage_events TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.city_profile_cover_assignments TO service_role;

CREATE OR REPLACE FUNCTION public.enqueue_city_profile_cover_fetch(
  p_city_profile_id uuid
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_job_id uuid;
  v_active_count integer;
BEGIN
  IF p_city_profile_id IS NULL THEN
    RETURN NULL;
  END IF;

  PERFORM 1 FROM public.city_profiles WHERE id = p_city_profile_id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT count(*) INTO v_active_count
  FROM public.city_profile_cover_images
  WHERE city_profile_id = p_city_profile_id
    AND is_active = true;

  IF v_active_count >= 5 THEN
    RETURN NULL;
  END IF;

  INSERT INTO public.city_profile_cover_fetch_jobs (city_profile_id, status, run_after)
  VALUES (p_city_profile_id, 'pending', now())
  ON CONFLICT (city_profile_id) WHERE status IN ('pending', 'processing')
  DO UPDATE SET
    run_after = LEAST(public.city_profile_cover_fetch_jobs.run_after, EXCLUDED.run_after),
    last_error = NULL,
    updated_at = now()
  RETURNING id INTO v_job_id;

  RETURN v_job_id;
END;
$$;

REVOKE ALL ON FUNCTION public.enqueue_city_profile_cover_fetch(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.enqueue_city_profile_cover_fetch(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.enqueue_missing_city_profile_cover_fetches(
  p_limit integer DEFAULT 25
) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count integer := 0;
  v_city record;
BEGIN
  FOR v_city IN
    SELECT cp.id
    FROM public.city_profiles cp
    LEFT JOIN LATERAL (
      SELECT count(*) AS active_count
      FROM public.city_profile_cover_images cpi
      WHERE cpi.city_profile_id = cp.id
        AND cpi.is_active = true
    ) pool ON true
    WHERE coalesce(pool.active_count, 0) < 5
    ORDER BY cp.created_at ASC
    LIMIT greatest(1, least(coalesce(p_limit, 25), 100))
  LOOP
    IF public.enqueue_city_profile_cover_fetch(v_city.id) IS NOT NULL THEN
      v_count := v_count + 1;
    END IF;
  END LOOP;

  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.enqueue_missing_city_profile_cover_fetches(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.enqueue_missing_city_profile_cover_fetches(integer) TO service_role;

CREATE OR REPLACE FUNCTION public.pick_city_profile_cover_image(
  p_city_profile_id uuid,
  p_trip_id uuid DEFAULT NULL
) RETURNS TABLE (
  cover_image_id uuid,
  city_profile_id uuid,
  image_url text,
  cover_attribution text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_cover public.city_profile_cover_images%ROWTYPE;
  v_assignment_user uuid;
BEGIN
  IF p_city_profile_id IS NULL OR v_user_id IS NULL THEN
    RETURN;
  END IF;

  IF p_trip_id IS NOT NULL THEN
    IF NOT public.can_edit_trip(p_trip_id) THEN
      RAISE EXCEPTION 'not allowed to assign cover for trip %', p_trip_id
        USING ERRCODE = '42501';
    END IF;
    SELECT user_id INTO v_assignment_user
    FROM public.trips
    WHERE id = p_trip_id;
  ELSE
    v_assignment_user := v_user_id;
  END IF;

  SELECT *
  INTO v_cover
  FROM public.city_profile_cover_images cpi
  WHERE cpi.city_profile_id = p_city_profile_id
    AND cpi.is_active = true
  ORDER BY cpi.assignment_count ASC,
           cpi.last_assigned_at ASC NULLS FIRST,
           random()
  LIMIT 1
  FOR UPDATE SKIP LOCKED;

  IF NOT FOUND THEN
    PERFORM public.enqueue_city_profile_cover_fetch(p_city_profile_id);
    RETURN;
  END IF;

  UPDATE public.city_profile_cover_images cpi
  SET assignment_count = cpi.assignment_count + 1,
      last_assigned_at = now(),
      updated_at = now()
  WHERE cpi.id = v_cover.id;

  INSERT INTO public.city_profile_cover_assignments (
    city_profile_id,
    cover_image_id,
    trip_id,
    assigned_to_user_id,
    download_location
  )
  VALUES (
    v_cover.city_profile_id,
    v_cover.id,
    p_trip_id,
    v_assignment_user,
    v_cover.download_location
  );

  cover_image_id := v_cover.id;
  city_profile_id := v_cover.city_profile_id;
  image_url := v_cover.image_url;
  cover_attribution := jsonb_build_object(
    'source', v_cover.source,
    'photographer', v_cover.photographer_name,
    'photographerUsername', v_cover.photographer_username,
    'photographerUrl', v_cover.photographer_url,
    'photoPageUrl', v_cover.photo_page_url,
    'text', trim(both ' ' from concat('Photo by ', coalesce(v_cover.photographer_name, 'Unsplash'), ' on Unsplash'))
  )::text;
  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION public.pick_city_profile_cover_image(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pick_city_profile_cover_image(uuid, uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.claim_city_profile_cover_fetch_jobs(
  p_batch_size integer DEFAULT 5
) RETURNS SETOF public.city_profile_cover_fetch_jobs
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  WITH picked AS (
    SELECT j.id
    FROM public.city_profile_cover_fetch_jobs j
    WHERE j.status IN ('pending', 'failed')
      AND j.run_after <= now()
      AND j.attempts < 8
    ORDER BY j.created_at ASC
    LIMIT greatest(1, least(coalesce(p_batch_size, 5), 25))
    FOR UPDATE SKIP LOCKED
  )
  UPDATE public.city_profile_cover_fetch_jobs j
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

REVOKE ALL ON FUNCTION public.claim_city_profile_cover_fetch_jobs(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.claim_city_profile_cover_fetch_jobs(integer) TO service_role;

CREATE OR REPLACE FUNCTION public.claim_city_profile_cover_download_assignments(
  p_batch_size integer DEFAULT 25
) RETURNS SETOF public.city_profile_cover_assignments
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  WITH picked AS (
    SELECT a.id
    FROM public.city_profile_cover_assignments a
    WHERE a.download_location IS NOT NULL
      AND a.download_tracked_at IS NULL
      AND a.download_track_attempts < 5
    ORDER BY a.created_at ASC
    LIMIT greatest(1, least(coalesce(p_batch_size, 25), 100))
    FOR UPDATE SKIP LOCKED
  )
  UPDATE public.city_profile_cover_assignments a
  SET download_track_attempts = a.download_track_attempts + 1
  FROM picked
  WHERE a.id = picked.id
  RETURNING a.*;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_city_profile_cover_download_assignments(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.claim_city_profile_cover_download_assignments(integer) TO service_role;

CREATE OR REPLACE FUNCTION public.record_external_api_usage_event(
  p_provider text,
  p_endpoint text,
  p_city_profile_id uuid DEFAULT NULL,
  p_request_count integer DEFAULT 1,
  p_status text DEFAULT 'success',
  p_meta jsonb DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_provider IS NULL OR p_endpoint IS NULL THEN
    RETURN;
  END IF;

  INSERT INTO public.external_api_usage_events (
    provider,
    endpoint,
    city_profile_id,
    request_count,
    status,
    meta
  )
  VALUES (
    p_provider,
    p_endpoint,
    p_city_profile_id,
    greatest(coalesce(p_request_count, 1), 1),
    coalesce(p_status, 'success'),
    p_meta
  );
END;
$$;

REVOKE ALL ON FUNCTION public.record_external_api_usage_event(text, text, uuid, integer, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_external_api_usage_event(text, text, uuid, integer, text, jsonb) TO service_role;

-- Optional production backfill/maintenance loop. Safe to skip locally if pg_cron
-- or pg_net is unavailable; the Edge Function can also be invoked manually with
-- `{ "backfill_missing": true }`.
DO $$
DECLARE
  jid integer;
BEGIN
  IF exists (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    SELECT jobid INTO jid
    FROM cron.job
    WHERE jobname IN (
      'city-cover-images-every-15-minutes',
      'city-cover-images-every-3-minutes'
    )
    LIMIT 1;

    IF jid IS NOT NULL THEN
      PERFORM cron.unschedule(jid);
    END IF;

    PERFORM cron.schedule(
      'city-cover-images-every-3-minutes',
      '*/3 * * * *',
      $cron$
      SELECT net.http_post(
        url := rtrim(
          (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'supabase_url' LIMIT 1),
          '/'
        ) || '/functions/v1/city-cover-images',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'x-worker-secret',
          (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'worker_secret' LIMIT 1)
        ),
        body := jsonb_build_object(
          'batch_size', 1,
          'download_batch_size', 10,
          'backfill_missing', false
        )
      );
      $cron$
    );
  END IF;
END
$$;
