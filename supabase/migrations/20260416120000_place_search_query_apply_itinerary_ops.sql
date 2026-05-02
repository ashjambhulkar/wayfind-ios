-- Lazy AI place resolution: persist search text without Google at plan time; RPC applies inserts.
-- Also defines is_trip_editor + apply_itinerary_ops if missing (Edge uses service role).

ALTER TABLE public.trip_activities
  ADD COLUMN IF NOT EXISTS place_search_query text NULL;

COMMENT ON COLUMN public.trip_activities.place_search_query IS
  'Optional text used to resolve lat/lng/place_id client-side after AI plan (no Google on plan path).';

-- ─── is_trip_editor (explicit user id; for service-role Edge + SECURITY DEFINER RPCs) ───

CREATE OR REPLACE FUNCTION public.is_trip_editor(p_trip_id uuid, p_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.trips t
    WHERE t.id = p_trip_id
      AND t.user_id = p_user_id
  )
  OR EXISTS (
    SELECT 1
    FROM public.trip_collaborators tc
    WHERE tc.trip_id = p_trip_id
      AND tc.user_id = p_user_id
      AND tc.status = 'accepted'
      AND tc.role = 'editor'
  );
$$;

REVOKE ALL ON FUNCTION public.is_trip_editor(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_trip_editor(uuid, uuid) TO service_role;

-- ─── apply_itinerary_ops ───────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.apply_itinerary_ops(
  p_trip_id uuid,
  p_actor_id uuid,
  p_payload jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $fn$
DECLARE
  op jsonb;
  r jsonb;
  v_lat double precision;
  v_lng double precision;
  v_rating real;
  v_price int;
  v_cost numeric;
  v_dur int;
  v_sort int;
  v_travel int;
BEGIN
  IF NOT public.is_trip_editor(p_trip_id, p_actor_id) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF p_payload IS NULL OR jsonb_typeof(p_payload) != 'object' THEN
    RAISE EXCEPTION 'invalid payload' USING ERRCODE = '22023';
  END IF;

  FOR op IN SELECT value FROM jsonb_array_elements(COALESCE(p_payload->'ops', '[]'::jsonb)) AS t(value)
  LOOP
    IF op->>'action' = 'delete' THEN
      DELETE FROM public.trip_activities a
      WHERE a.id = (op->>'id')::uuid
        AND a.trip_id = p_trip_id;

    ELSIF op->>'action' = 'insert' THEN
      r := op->'row';
      IF r IS NULL OR jsonb_typeof(r) != 'object' THEN
        RAISE EXCEPTION 'insert op missing row' USING ERRCODE = '22023';
      END IF;

      v_lat := NULL;
      v_lng := NULL;
      IF r ? 'latitude' AND jsonb_typeof(r->'latitude') = 'number' THEN
        v_lat := (r->>'latitude')::double precision;
      ELSIF r->>'latitude' IS NOT NULL AND btrim(r->>'latitude') <> '' THEN
        v_lat := (r->>'latitude')::double precision;
      END IF;

      IF r ? 'longitude' AND jsonb_typeof(r->'longitude') = 'number' THEN
        v_lng := (r->>'longitude')::double precision;
      ELSIF r->>'longitude' IS NOT NULL AND btrim(r->>'longitude') <> '' THEN
        v_lng := (r->>'longitude')::double precision;
      END IF;

      v_rating := NULL;
      IF r ? 'rating' AND jsonb_typeof(r->'rating') = 'number' THEN
        v_rating := (r->>'rating')::real;
      ELSIF r->>'rating' IS NOT NULL AND btrim(r->>'rating') <> '' THEN
        v_rating := (r->>'rating')::real;
      END IF;

      v_price := NULL;
      IF r ? 'price_level' AND jsonb_typeof(r->'price_level') = 'number' THEN
        v_price := (r->>'price_level')::int;
      ELSIF r->>'price_level' IS NOT NULL AND btrim(r->>'price_level') <> '' THEN
        v_price := (r->>'price_level')::int;
      END IF;

      v_cost := NULL;
      IF r ? 'estimated_cost' AND jsonb_typeof(r->'estimated_cost') = 'number' THEN
        v_cost := (r->>'estimated_cost')::numeric;
      ELSIF r->>'estimated_cost' IS NOT NULL AND btrim(r->>'estimated_cost') <> '' THEN
        v_cost := (r->>'estimated_cost')::numeric;
      END IF;

      v_dur := NULL;
      IF r ? 'duration_minutes' AND jsonb_typeof(r->'duration_minutes') = 'number' THEN
        v_dur := (r->>'duration_minutes')::int;
      ELSIF r->>'duration_minutes' IS NOT NULL AND btrim(r->>'duration_minutes') <> '' THEN
        v_dur := (r->>'duration_minutes')::int;
      END IF;

      v_sort := COALESCE(
        CASE
          WHEN r ? 'sort_order' AND jsonb_typeof(r->'sort_order') = 'number' THEN (r->>'sort_order')::int
          WHEN r->>'sort_order' IS NOT NULL AND btrim(r->>'sort_order') <> '' THEN (r->>'sort_order')::int
          ELSE NULL
        END,
        0
      );

      v_travel := NULL;
      IF r ? 'travel_from_previous_minutes' AND jsonb_typeof(r->'travel_from_previous_minutes') = 'number' THEN
        v_travel := (r->>'travel_from_previous_minutes')::int;
      ELSIF r->>'travel_from_previous_minutes' IS NOT NULL AND btrim(r->>'travel_from_previous_minutes') <> '' THEN
        v_travel := (r->>'travel_from_previous_minutes')::int;
      END IF;

      INSERT INTO public.trip_activities (
        trip_id,
        day_id,
        user_id,
        name,
        description,
        category,
        starts_at,
        duration_minutes,
        latitude,
        longitude,
        address,
        place_id,
        estimated_cost,
        currency,
        rating,
        price_level,
        sort_order,
        travel_from_previous_minutes,
        directions_url,
        travel_mode,
        source,
        booking_id,
        hero_image_url,
        hero_attribution,
        place_search_query
      ) VALUES (
        p_trip_id,
        (r->>'day_id')::uuid,
        p_actor_id,
        left(COALESCE(r->>'name', 'Stop'), 500),
        NULLIF(btrim(COALESCE(r->>'description', '')), ''),
        NULLIF(btrim(COALESCE(r->>'category', '')), ''),
        CASE
          WHEN r->>'starts_at' IS NULL OR btrim(r->>'starts_at') = '' THEN NULL
          ELSE (r->>'starts_at')::timestamptz
        END,
        v_dur,
        v_lat,
        v_lng,
        NULLIF(btrim(COALESCE(r->>'address', '')), ''),
        NULLIF(btrim(COALESCE(r->>'place_id', '')), ''),
        v_cost,
        NULLIF(btrim(COALESCE(r->>'currency', '')), ''),
        v_rating,
        v_price,
        v_sort,
        v_travel,
        NULLIF(btrim(COALESCE(r->>'directions_url', '')), ''),
        COALESCE(NULLIF(btrim(COALESCE(r->>'travel_mode', '')), ''), 'driving'),
        'ai_suggestion',
        NULL,
        NULL,
        NULL,
        NULLIF(btrim(COALESCE(r->>'place_search_query', '')), '')
      );
    END IF;
  END LOOP;
END;
$fn$;

REVOKE ALL ON FUNCTION public.apply_itinerary_ops(uuid, uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.apply_itinerary_ops(uuid, uuid, jsonb) TO service_role;
