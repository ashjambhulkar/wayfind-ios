-- City cover image pool smoke test.
--
-- Run via the Supabase CLI after `supabase db reset`:
--   psql "$DB_URL" -f supabase/tests/city_profile_cover_images_smoke.sql
--
-- The script ROLLBACKs so it is safe to run repeatedly.

BEGIN;

DO $test$
DECLARE
  v_owner uuid;
  v_city uuid := gen_random_uuid();
  v_empty_city uuid := gen_random_uuid();
  v_trip uuid := gen_random_uuid();
  v_cover_1 uuid := gen_random_uuid();
  v_cover_2 uuid := gen_random_uuid();
  v_selected_1 uuid;
  v_selected_2 uuid;
  v_job_1 uuid;
  v_job_2 uuid;
  v_count int;
  v_usage int;
BEGIN
  SELECT id INTO v_owner FROM auth.users ORDER BY created_at LIMIT 1;
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'No auth.users in local DB; create one before running tests';
  END IF;

  PERFORM set_config('request.jwt.claim.sub', v_owner::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);

  INSERT INTO public.city_profiles (
    id,
    city_slug,
    display_name,
    country_code,
    center_lat,
    center_lng,
    city_search_label
  ) VALUES
    (v_city, 'cover-smoke-city', 'Cover Smoke City', 'US', 40.0, -73.0, 'Cover Smoke City'),
    (v_empty_city, 'cover-empty-city', 'Cover Empty City', 'US', 41.0, -74.0, 'Cover Empty City');

  INSERT INTO public.trips (
    id,
    user_id,
    name,
    destination,
    start_date,
    end_date,
    city_profile_id,
    budget_currency
  ) VALUES (
    v_trip,
    v_owner,
    'Cover smoke trip',
    'Cover Smoke City',
    current_date,
    current_date + 3,
    v_city,
    'USD'
  );

  INSERT INTO public.city_profile_cover_images (
    id,
    city_profile_id,
    source_photo_id,
    image_url,
    photographer_name,
    download_location,
    position
  ) VALUES
    (v_cover_1, v_city, 'unsplash-a', 'https://images.unsplash.com/a', 'A', 'https://api.unsplash.com/photos/a/download', 0),
    (v_cover_2, v_city, 'unsplash-b', 'https://images.unsplash.com/b', 'B', 'https://api.unsplash.com/photos/b/download', 1);

  SELECT cover_image_id INTO v_selected_1
  FROM public.pick_city_profile_cover_image(v_city, v_trip)
  LIMIT 1;

  SELECT cover_image_id INTO v_selected_2
  FROM public.pick_city_profile_cover_image(v_city, v_trip)
  LIMIT 1;

  IF v_selected_1 IS NULL OR v_selected_2 IS NULL THEN
    RAISE EXCEPTION 'Cover pick FAILED: expected two selections';
  END IF;
  IF v_selected_1 = v_selected_2 THEN
    RAISE EXCEPTION 'Cover rotation FAILED: second pick should prefer the unused image';
  END IF;

  SELECT count(*) INTO v_count
  FROM public.city_profile_cover_assignments
  WHERE trip_id = v_trip
    AND download_location IS NOT NULL;

  IF v_count <> 2 THEN
    RAISE EXCEPTION 'Assignment audit FAILED: expected 2 rows, got %', v_count;
  END IF;
  RAISE NOTICE 'Cover selection rotation and assignment audit passed';

  SELECT public.enqueue_city_profile_cover_fetch(v_empty_city) INTO v_job_1;
  SELECT public.enqueue_city_profile_cover_fetch(v_empty_city) INTO v_job_2;

  SELECT count(*) INTO v_count
  FROM public.city_profile_cover_fetch_jobs
  WHERE city_profile_id = v_empty_city
    AND status IN ('pending', 'processing');

  IF v_job_1 IS NULL OR v_job_2 IS NULL OR v_count <> 1 THEN
    RAISE EXCEPTION 'Duplicate job prevention FAILED: job1=% job2=% active_count=%',
      v_job_1, v_job_2, v_count;
  END IF;
  RAISE NOTICE 'Duplicate fetch job prevention passed';

  IF has_table_privilege('authenticated', 'public.city_profile_cover_fetch_jobs', 'INSERT') THEN
    RAISE EXCEPTION 'RLS/grants FAILED: authenticated should not insert fetch jobs directly';
  END IF;
  IF has_table_privilege('authenticated', 'public.external_api_usage_events', 'SELECT') THEN
    RAISE EXCEPTION 'RLS/grants FAILED: authenticated should not read quota ledger directly';
  END IF;
  RAISE NOTICE 'RLS grant checks passed';

  PERFORM public.record_external_api_usage_event(
    'unsplash',
    'search/photos',
    v_city,
    1,
    'success',
    '{"smoke": true}'::jsonb
  );

  SELECT coalesce(sum(request_count), 0)::int INTO v_usage
  FROM public.external_api_usage_events
  WHERE provider = 'unsplash'
    AND endpoint = 'search/photos'
    AND created_at >= now() - interval '1 hour';

  IF v_usage < 1 THEN
    RAISE EXCEPTION 'Quota ledger FAILED: expected recent usage event';
  END IF;
  RAISE NOTICE 'Quota ledger smoke check passed';

  RAISE NOTICE 'ALL CITY COVER IMAGE TESTS PASSED';
END;
$test$;

ROLLBACK;
