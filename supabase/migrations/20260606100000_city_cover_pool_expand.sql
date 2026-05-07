-- Align city cover pool target with edge function (larger pool + quality ranking).
-- Previously capped at 5 rows, so cities never backfilled beyond the first small batch.

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

  -- Must match TARGET_POOL_SIZE in supabase/functions/city-cover-images/index.ts
  IF v_active_count >= 12 THEN
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
    WHERE coalesce(pool.active_count, 0) < 12
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
