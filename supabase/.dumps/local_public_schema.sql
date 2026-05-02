


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "public";


ALTER SCHEMA "public" OWNER TO "pg_database_owner";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE OR REPLACE FUNCTION "public"."accept_invite"("invite_token" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_invite public.trip_invites%ROWTYPE;
  v_existing public.trip_collaborators%ROWTYPE;
  v_count integer;
BEGIN
  IF invite_token IS NULL OR length(trim(invite_token)) = 0 THEN
    RETURN jsonb_build_object('error', 'Invalid or expired invite');
  END IF;

  SELECT *
  INTO v_invite
  FROM public.trip_invites
  WHERE token = invite_token
    AND is_active = true
    AND (expires_at IS NULL OR expires_at > now())
    AND (max_uses IS NULL OR uses < max_uses)
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'Invalid or expired invite');
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.trips tr WHERE tr.id = v_invite.trip_id AND tr.user_id = (SELECT auth.uid())
  ) THEN
    RETURN jsonb_build_object('error', 'You already own this trip');
  END IF;

  SELECT *
  INTO v_existing
  FROM public.trip_collaborators
  WHERE trip_id = v_invite.trip_id
    AND user_id = (SELECT auth.uid());

  IF FOUND THEN
    RETURN jsonb_build_object('error', 'Already a collaborator');
  END IF;

  SELECT count(*)::integer
  INTO v_count
  FROM public.trip_collaborators
  WHERE trip_id = v_invite.trip_id
    AND status = 'accepted';

  IF v_count >= 25 THEN
    RETURN jsonb_build_object('error', 'This trip has reached the collaborator limit');
  END IF;

  INSERT INTO public.trip_collaborators (trip_id, user_id, role, status)
  VALUES (v_invite.trip_id, (SELECT auth.uid()), v_invite.role, 'accepted');

  UPDATE public.trip_invites
  SET uses = uses + 1
  WHERE id = v_invite.id;

  INSERT INTO public.trip_activity_log (trip_id, user_id, action, entity_type, entity_id, metadata)
  VALUES (
    v_invite.trip_id,
    (SELECT auth.uid()),
    'collaborator_joined',
    'collaborator',
    (SELECT auth.uid()),
    jsonb_build_object('role', v_invite.role)
  );

  RETURN jsonb_build_object(
    'success', true,
    'trip_id', v_invite.trip_id,
    'role', v_invite.role
  );
END;
$$;


ALTER FUNCTION "public"."accept_invite"("invite_token" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."accept_pending_collaborator"("p_trip_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_row public.trip_collaborators%ROWTYPE;
  v_count integer;
BEGIN
  IF p_trip_id IS NULL THEN
    RETURN jsonb_build_object('error', 'Invalid trip');
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.trips tr WHERE tr.id = p_trip_id AND tr.user_id = (SELECT auth.uid())
  ) THEN
    RETURN jsonb_build_object('error', 'You own this trip');
  END IF;

  SELECT *
  INTO v_row
  FROM public.trip_collaborators
  WHERE trip_id = p_trip_id
    AND user_id = (SELECT auth.uid())
    AND status = 'pending'
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'No pending invite for this trip');
  END IF;

  SELECT count(*)::integer
  INTO v_count
  FROM public.trip_collaborators
  WHERE trip_id = p_trip_id
    AND status = 'accepted';

  IF v_count >= 25 THEN
    RETURN jsonb_build_object('error', 'This trip has reached the collaborator limit');
  END IF;

  UPDATE public.trip_collaborators
  SET status = 'accepted'
  WHERE id = v_row.id;

  INSERT INTO public.trip_activity_log (trip_id, user_id, action, entity_type, entity_id, metadata)
  VALUES (
    p_trip_id,
    (SELECT auth.uid()),
    'collaborator_joined',
    'collaborator',
    (SELECT auth.uid()),
    jsonb_build_object('role', v_row.role, 'via', 'email_pending')
  );

  RETURN jsonb_build_object(
    'success', true,
    'trip_id', p_trip_id,
    'role', v_row.role
  );
END;
$$;


ALTER FUNCTION "public"."accept_pending_collaborator"("p_trip_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."apply_itinerary_ops"("p_trip_id" "uuid", "p_actor_id" "uuid", "p_payload" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    SET "row_security" TO 'off'
    AS $$
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
  v_meal_anchor boolean;
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

      v_meal_anchor := false;
      IF r ? 'meal_anchor' AND jsonb_typeof(r->'meal_anchor') = 'boolean' THEN
        v_meal_anchor := (r->>'meal_anchor')::boolean;
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
        place_search_query,
        meal_anchor
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
        NULLIF(btrim(COALESCE(r->>'place_search_query', '')), ''),
        v_meal_anchor
      );
    END IF;
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."apply_itinerary_ops"("p_trip_id" "uuid", "p_actor_id" "uuid", "p_payload" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."can_edit_trip"("p_trip_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    SET "row_security" TO 'off'
    AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.trips t
    WHERE t.id = p_trip_id
      AND t.user_id = (SELECT auth.uid())
  )
  OR EXISTS (
    SELECT 1
    FROM public.trip_collaborators tc
    WHERE tc.trip_id = p_trip_id
      AND tc.user_id = (SELECT auth.uid())
      AND tc.status = 'accepted'
      AND tc.role = 'editor'
  );
$$;


ALTER FUNCTION "public"."can_edit_trip"("p_trip_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."can_view_trip"("p_trip_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    SET "row_security" TO 'off'
    AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.trips t
    WHERE t.id = p_trip_id
      AND t.user_id = (SELECT auth.uid())
  )
  OR EXISTS (
    SELECT 1
    FROM public.trip_collaborators tc
    WHERE tc.trip_id = p_trip_id
      AND tc.user_id = (SELECT auth.uid())
      AND tc.status IN ('accepted', 'pending')
  );
$$;


ALTER FUNCTION "public"."can_view_trip"("p_trip_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."checklist_items_bump_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."checklist_items_bump_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."checklist_items_sync_trip_id"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_trip uuid;
BEGIN
  SELECT c.trip_id INTO v_trip
  FROM public.trip_checklists c
  WHERE c.id = NEW.checklist_id;
  IF v_trip IS NULL THEN
    RAISE EXCEPTION 'checklist_id % not found', NEW.checklist_id;
  END IF;
  NEW.trip_id := v_trip;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."checklist_items_sync_trip_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."claim_ai_usage"("p_user_id" "uuid", "p_feature" "text", "p_monthly_limit" integer) RETURNS TABLE("ok" boolean, "reason" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_is_pro boolean;
  v_expires timestamptz;
  v_count integer;
  v_month_start timestamptz := date_trunc('month', timezone('utc', now()));
  v_lock_key bigint;
BEGIN
  IF p_user_id IS NULL OR p_feature IS NULL OR length(trim(p_feature)) = 0 THEN
    RETURN QUERY SELECT false, 'invalid_arguments'::text;
    RETURN;
  END IF;

  SELECT us.is_pro, us.expires_at
  INTO v_is_pro, v_expires
  FROM public.user_subscriptions us
  WHERE us.user_id = p_user_id;

  IF coalesce(v_is_pro, false)
    AND (v_expires IS NULL OR v_expires > timezone('utc', now())) THEN
    RETURN QUERY SELECT true, 'pro'::text;
    RETURN;
  END IF;

  IF p_monthly_limit <= 0 THEN
    RETURN QUERY SELECT false, 'feature_requires_pro'::text;
    RETURN;
  END IF;

  -- Single-transaction lock per user+feature+calendar month (hashtext = int4 → bigint).
  v_lock_key := hashtext(
    p_user_id::text || '|' || p_feature || '|' || to_char(v_month_start, 'YYYY-MM')
  )::bigint;
  PERFORM pg_advisory_xact_lock(v_lock_key);

  SELECT count(*)::integer
  INTO v_count
  FROM public.usage_events ue
  WHERE ue.user_id = p_user_id
    AND ue.feature = p_feature
    AND ue.created_at >= v_month_start;

  IF v_count >= p_monthly_limit THEN
    RETURN QUERY SELECT false, 'limit_exceeded'::text;
    RETURN;
  END IF;

  INSERT INTO public.usage_events (user_id, feature, metadata)
  VALUES (
    p_user_id,
    p_feature,
    jsonb_build_object('source', 'claim_ai_usage')
  );

  RETURN QUERY SELECT true, 'claimed'::text;
  RETURN;
END
$$;


ALTER FUNCTION "public"."claim_ai_usage"("p_user_id" "uuid", "p_feature" "text", "p_monthly_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."enforce_trip_activity_max_photos"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  cnt integer;
BEGIN
  IF NOT (
    NEW.mime_type ILIKE 'image/%'
    OR LOWER(COALESCE(NEW.attachment_type, '')) IN ('photo', 'image')
  ) THEN
    RETURN NEW;
  END IF;

  SELECT COUNT(*)::integer
  INTO cnt
  FROM public.trip_activity_attachments
  WHERE activity_id = NEW.activity_id
    AND (
      mime_type ILIKE 'image/%'
      OR LOWER(COALESCE(attachment_type, '')) IN ('photo', 'image')
    );

  IF cnt >= 5 THEN
    RAISE EXCEPTION 'ACTIVITY_PHOTO_LIMIT'
      USING DETAIL = 'Maximum 5 photos per activity.';
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."enforce_trip_activity_max_photos"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."enforce_trip_activity_max_photos"() IS 'Rejects insert when activity already has 5 image-like attachments.';



CREATE OR REPLACE FUNCTION "public"."ensure_trip_checklist_templates"("p_trip_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    SET "row_security" TO 'off'
    AS $$
DECLARE
  v_owner uuid;
  v_cid uuid;
BEGIN
  IF NOT public.can_view_trip(p_trip_id) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT t.user_id INTO v_owner FROM public.trips t WHERE t.id = p_trip_id;
  IF v_owner IS NULL THEN
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.trip_checklists c WHERE c.trip_id = p_trip_id AND c.template_key = 'packing'
  ) THEN
    INSERT INTO public.trip_checklists (trip_id, user_id, title, sort_order, template_key)
    VALUES (p_trip_id, v_owner, 'Packing', 0, 'packing')
    RETURNING id INTO v_cid;

    INSERT INTO public.checklist_items (checklist_id, trip_id, user_id, title, sort_order, is_done)
    VALUES
      (v_cid, p_trip_id, v_owner, 'Passport & visa', 0, false),
      (v_cid, p_trip_id, v_owner, 'Travel adapter (EU plug)', 1, false),
      (v_cid, p_trip_id, v_owner, 'Rough itinerary sketch', 2, false),
      (v_cid, p_trip_id, v_owner, 'Comfortable walking shoes', 3, false),
      (v_cid, p_trip_id, v_owner, 'Camera & chargers', 4, false),
      (v_cid, p_trip_id, v_owner, 'Light jacket (evenings)', 5, false);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.trip_checklists c WHERE c.trip_id = p_trip_id AND c.template_key = 'todo'
  ) THEN
    INSERT INTO public.trip_checklists (trip_id, user_id, title, sort_order, template_key)
    VALUES (p_trip_id, v_owner, 'To-Do', 1, 'todo')
    RETURNING id INTO v_cid;

    INSERT INTO public.checklist_items (checklist_id, trip_id, user_id, title, sort_order, is_done)
    VALUES
      (v_cid, p_trip_id, v_owner, 'Book airport transfer', 0, false),
      (v_cid, p_trip_id, v_owner, 'Confirm hotel check-in time', 1, false),
      (v_cid, p_trip_id, v_owner, 'Download offline maps', 2, false),
      (v_cid, p_trip_id, v_owner, 'Notify bank of travel', 3, false);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.trip_checklists c WHERE c.trip_id = p_trip_id AND c.template_key = 'documents'
  ) THEN
    INSERT INTO public.trip_checklists (trip_id, user_id, title, sort_order, template_key)
    VALUES (p_trip_id, v_owner, 'Documents', 2, 'documents')
    RETURNING id INTO v_cid;

    INSERT INTO public.checklist_items (checklist_id, trip_id, user_id, title, sort_order, is_done)
    VALUES
      (v_cid, p_trip_id, v_owner, 'Passport copy (digital)', 0, false),
      (v_cid, p_trip_id, v_owner, 'Travel insurance details', 1, false),
      (v_cid, p_trip_id, v_owner, 'Flight or train confirmations', 2, false),
      (v_cid, p_trip_id, v_owner, 'Hotel booking confirmation', 3, false);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.trip_checklists c WHERE c.trip_id = p_trip_id AND c.template_key = 'general'
  ) THEN
    INSERT INTO public.trip_checklists (trip_id, user_id, title, sort_order, template_key)
    VALUES (p_trip_id, v_owner, 'General', 3, 'general');
  END IF;
END;
$$;


ALTER FUNCTION "public"."ensure_trip_checklist_templates"("p_trip_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_invite_preview"("invite_token" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  r record;
BEGIN
  SELECT
    ti.id,
    ti.role,
    ti.expires_at,
    ti.max_uses,
    ti.uses,
    ti.is_active,
    t.id AS trip_id,
    t.name,
    t.cover_image_url,
    t.start_date,
    t.end_date,
    t.destination,
    p.display_name AS inviter_name
  INTO r
  FROM public.trip_invites ti
  JOIN public.trips t ON t.id = ti.trip_id
  LEFT JOIN public.profiles p ON p.id = ti.created_by
  WHERE ti.token = invite_token;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'Invite not found');
  END IF;

  IF
    NOT r.is_active
    OR (r.expires_at IS NOT NULL AND r.expires_at <= now())
    OR (r.max_uses IS NOT NULL AND r.uses >= r.max_uses)
  THEN
    RETURN jsonb_build_object('error', 'Invalid or expired invite');
  END IF;

  RETURN jsonb_build_object(
    'trip_id', r.trip_id,
    'role', r.role,
    'trip_name', r.name,
    'cover_image_url', r.cover_image_url,
    'start_date', r.start_date,
    'end_date', r.end_date,
    'destination', r.destination,
    'inviter_name', r.inviter_name
  );
END;
$$;


ALTER FUNCTION "public"."get_invite_preview"("invite_token" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_trip_owner_profile_snippet"("p_trip_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    SET "row_security" TO 'off'
    AS $$
DECLARE
  v_owner_id uuid;
  v_display text;
  v_avatar text;
  v_username text;
BEGIN
  IF p_trip_id IS NULL THEN
    RETURN NULL::jsonb;
  END IF;

  IF NOT public.can_view_trip(p_trip_id) THEN
    RETURN NULL::jsonb;
  END IF;

  SELECT t.user_id
  INTO v_owner_id
  FROM public.trips t
  WHERE t.id = p_trip_id;

  IF v_owner_id IS NULL THEN
    RETURN NULL::jsonb;
  END IF;

  SELECT p.display_name, p.avatar_url, p.username
  INTO v_display, v_avatar, v_username
  FROM public.profiles p
  WHERE p.id = v_owner_id;

  RETURN jsonb_build_object(
    'display_name', v_display,
    'avatar_url', v_avatar,
    'username', v_username
  );
END;
$$;


ALTER FUNCTION "public"."get_trip_owner_profile_snippet"("p_trip_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_trip_editor"("p_trip_id" "uuid", "p_user_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    SET "row_security" TO 'off'
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


ALTER FUNCTION "public"."is_trip_editor"("p_trip_id" "uuid", "p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_trip_member"("p_trip_id" "uuid", "p_user_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    SET "row_security" TO 'off'
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
      AND tc.status IN ('accepted', 'pending')
  );
$$;


ALTER FUNCTION "public"."is_trip_member"("p_trip_id" "uuid", "p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_trip_owner"("p_trip_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE
    AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.trips t
    WHERE t.id = p_trip_id
      AND t.user_id = (SELECT auth.uid())
  );
$$;


ALTER FUNCTION "public"."is_trip_owner"("p_trip_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."list_trip_collaborator_profile_snippets"("p_trip_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    SET "row_security" TO 'off'
    AS $$
BEGIN
  IF p_trip_id IS NULL THEN
    RETURN '[]'::jsonb;
  END IF;

  IF NOT public.can_view_trip(p_trip_id) THEN
    RETURN '[]'::jsonb;
  END IF;

  RETURN COALESCE(
    (
      SELECT jsonb_agg(
        jsonb_build_object(
          'user_id', x.user_id,
          'display_name', x.display_name,
          'username', x.username,
          'avatar_url', x.avatar_url,
          'email', x.email
        )
        ORDER BY x.user_id
      )
      FROM (
        SELECT
          tc.user_id,
          p.display_name,
          p.username,
          p.avatar_url,
          au.email::text AS email
        FROM public.trip_collaborators tc
        LEFT JOIN public.profiles p ON p.id = tc.user_id
        LEFT JOIN auth.users au ON au.id = tc.user_id
        WHERE tc.trip_id = p_trip_id
          AND tc.status = 'accepted'
          AND tc.user_id IS NOT NULL
      ) x
    ),
    '[]'::jsonb
  );
END;
$$;


ALTER FUNCTION "public"."list_trip_collaborator_profile_snippets"("p_trip_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."lookup_auth_user_id_by_email"("p_email" "text") RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'auth', 'public'
    AS $$
  SELECT u.id
  FROM auth.users u
  WHERE lower(trim(u.email::text)) = lower(trim(p_email))
  LIMIT 1;
$$;


ALTER FUNCTION "public"."lookup_auth_user_id_by_email"("p_email" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tg_log_pending_invite_declined"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF OLD.status = 'pending'
     AND (SELECT auth.uid()) IS NOT NULL
     AND (SELECT auth.uid()) = OLD.user_id
  THEN
    IF NOT EXISTS (SELECT 1 FROM public.trips t WHERE t.id = OLD.trip_id) THEN
      RETURN OLD;
    END IF;
    INSERT INTO public.trip_activity_log (trip_id, user_id, action, entity_type, entity_id, metadata)
    VALUES (
      OLD.trip_id,
      OLD.user_id,
      'pending_invite_declined',
      'collaborator',
      OLD.id,
      jsonb_build_object(
        'invited_email', OLD.invited_email,
        'role', OLD.role
      )
    );
  END IF;
  RETURN OLD;
END;
$$;


ALTER FUNCTION "public"."tg_log_pending_invite_declined"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tg_log_trip_activity_changes"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_actor uuid;
  v_trip_id uuid;
  v_activity_id uuid;
  v_name text;
BEGIN
  IF tg_op = 'INSERT' THEN
    v_trip_id := NEW.trip_id;
    v_activity_id := NEW.id;
    v_name := NEW.name;
    v_actor := COALESCE(
      NEW.user_id,
      (SELECT t.user_id FROM public.trips t WHERE t.id = NEW.trip_id LIMIT 1)
    );
    IF v_actor IS NULL THEN
      RETURN NEW;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.trips t WHERE t.id = v_trip_id) THEN
      RETURN NEW;
    END IF;
    INSERT INTO public.trip_activity_log (trip_id, user_id, action, entity_type, entity_id, entity_name)
    VALUES (
      v_trip_id,
      v_actor,
      'activity_added',
      'trip_activity',
      v_activity_id,
      v_name
    );
    RETURN NEW;
  ELSIF tg_op = 'UPDATE' THEN
    v_trip_id := NEW.trip_id;
    v_activity_id := NEW.id;
    v_name := NEW.name;
    v_actor := COALESCE(
      NEW.user_id,
      (SELECT t.user_id FROM public.trips t WHERE t.id = NEW.trip_id LIMIT 1)
    );
    IF v_actor IS NULL THEN
      RETURN NEW;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.trips t WHERE t.id = v_trip_id) THEN
      RETURN NEW;
    END IF;
    INSERT INTO public.trip_activity_log (trip_id, user_id, action, entity_type, entity_id, entity_name)
    VALUES (
      v_trip_id,
      v_actor,
      'activity_updated',
      'trip_activity',
      v_activity_id,
      v_name
    );
    RETURN NEW;
  ELSIF tg_op = 'DELETE' THEN
    v_trip_id := OLD.trip_id;
    v_activity_id := OLD.id;
    v_name := OLD.name;
    v_actor := COALESCE(
      OLD.user_id,
      (SELECT t.user_id FROM public.trips t WHERE t.id = OLD.trip_id LIMIT 1)
    );
    IF v_actor IS NULL THEN
      RETURN OLD;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.trips t WHERE t.id = v_trip_id) THEN
      RETURN OLD;
    END IF;
    INSERT INTO public.trip_activity_log (trip_id, user_id, action, entity_type, entity_id, entity_name)
    VALUES (
      v_trip_id,
      v_actor,
      'activity_deleted',
      'trip_activity',
      v_activity_id,
      v_name
    );
    RETURN OLD;
  END IF;
  RETURN NULL;
END;
$$;


ALTER FUNCTION "public"."tg_log_trip_activity_changes"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tg_log_trip_booking_changes"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_actor uuid;
  v_trip_id uuid;
  v_booking_id uuid;
  v_title text;
BEGIN
  IF tg_op = 'INSERT' THEN
    v_trip_id := NEW.trip_id;
    v_booking_id := NEW.id;
    v_title := COALESCE(NULLIF(trim(NEW.title), ''), 'Booking');
    v_actor := COALESCE(
      NEW.user_id,
      (SELECT t.user_id FROM public.trips t WHERE t.id = NEW.trip_id LIMIT 1)
    );
    IF v_actor IS NULL THEN
      RETURN NEW;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.trips t WHERE t.id = v_trip_id) THEN
      RETURN NEW;
    END IF;
    INSERT INTO public.trip_activity_log (trip_id, user_id, action, entity_type, entity_id, entity_name)
    VALUES (
      v_trip_id,
      v_actor,
      'booking_added',
      'trip_booking',
      v_booking_id,
      v_title
    );
    RETURN NEW;
  ELSIF tg_op = 'UPDATE' THEN
    v_trip_id := NEW.trip_id;
    v_booking_id := NEW.id;
    v_title := COALESCE(NULLIF(trim(NEW.title), ''), 'Booking');
    v_actor := COALESCE(
      NEW.user_id,
      (SELECT t.user_id FROM public.trips t WHERE t.id = NEW.trip_id LIMIT 1)
    );
    IF v_actor IS NULL THEN
      RETURN NEW;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.trips t WHERE t.id = v_trip_id) THEN
      RETURN NEW;
    END IF;
    INSERT INTO public.trip_activity_log (trip_id, user_id, action, entity_type, entity_id, entity_name)
    VALUES (
      v_trip_id,
      v_actor,
      'booking_updated',
      'trip_booking',
      v_booking_id,
      v_title
    );
    RETURN NEW;
  ELSIF tg_op = 'DELETE' THEN
    v_trip_id := OLD.trip_id;
    v_booking_id := OLD.id;
    v_title := COALESCE(NULLIF(trim(OLD.title), ''), 'Booking');
    v_actor := COALESCE(
      OLD.user_id,
      (SELECT t.user_id FROM public.trips t WHERE t.id = OLD.trip_id LIMIT 1)
    );
    IF v_actor IS NULL THEN
      RETURN OLD;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.trips t WHERE t.id = v_trip_id) THEN
      RETURN OLD;
    END IF;
    INSERT INTO public.trip_activity_log (trip_id, user_id, action, entity_type, entity_id, entity_name)
    VALUES (
      v_trip_id,
      v_actor,
      'booking_deleted',
      'trip_booking',
      v_booking_id,
      v_title
    );
    RETURN OLD;
  END IF;
  RETURN NULL;
END;
$$;


ALTER FUNCTION "public"."tg_log_trip_booking_changes"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tg_log_trip_collaborator_leave"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_voluntary boolean;
BEGIN
  IF OLD.status = 'accepted' THEN
    IF NOT EXISTS (SELECT 1 FROM public.trips t WHERE t.id = OLD.trip_id) THEN
      RETURN OLD;
    END IF;
    v_voluntary :=
      (SELECT auth.uid()) IS NOT NULL
      AND (SELECT auth.uid()) = OLD.user_id;

    INSERT INTO public.trip_activity_log (trip_id, user_id, action, entity_type, entity_id, metadata)
    VALUES (
      OLD.trip_id,
      OLD.user_id,
      'collaborator_left',
      'collaborator',
      OLD.user_id,
      jsonb_build_object(
        'role', OLD.role,
        'voluntary_leave', v_voluntary
      )
    );
  END IF;
  RETURN OLD;
END;
$$;


ALTER FUNCTION "public"."tg_log_trip_collaborator_leave"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tg_log_trip_collaborator_role"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_actor uuid;
BEGIN
  IF tg_op = 'UPDATE'
     AND NEW.status = 'accepted'
     AND OLD.role IS DISTINCT FROM NEW.role
  THEN
    v_actor := (SELECT auth.uid());
    IF v_actor IS NOT NULL THEN
      IF NOT EXISTS (SELECT 1 FROM public.trips t WHERE t.id = NEW.trip_id) THEN
        RETURN NEW;
      END IF;
      INSERT INTO public.trip_activity_log (trip_id, user_id, action, entity_type, entity_id, metadata)
      VALUES (
        NEW.trip_id,
        v_actor,
        'collaborator_role_changed',
        'collaborator',
        NEW.user_id,
        jsonb_build_object(
          'from_role', OLD.role,
          'to_role', NEW.role,
          'subject_user_id', NEW.user_id
        )
      );
    END IF;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."tg_log_trip_collaborator_role"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tg_log_trip_updated"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_actor uuid;
BEGIN
  IF tg_op = 'UPDATE' THEN
    IF OLD.name IS DISTINCT FROM NEW.name
       OR OLD.start_date IS DISTINCT FROM NEW.start_date
       OR OLD.end_date IS DISTINCT FROM NEW.end_date
       OR OLD.destination IS DISTINCT FROM NEW.destination
       OR OLD.status IS DISTINCT FROM NEW.status
       OR COALESCE(OLD.description, '') IS DISTINCT FROM COALESCE(NEW.description, '')
    THEN
      v_actor := (SELECT auth.uid());
      IF v_actor IS NOT NULL THEN
        INSERT INTO public.trip_activity_log (trip_id, user_id, action, entity_type, entity_id, entity_name)
        VALUES (
          NEW.id,
          v_actor,
          'trip_updated',
          'trip',
          NEW.id,
          NEW.name
        );
      END IF;
    END IF;
    RETURN NEW;
  END IF;
  RETURN NULL;
END;
$$;


ALTER FUNCTION "public"."tg_log_trip_updated"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trip_checklists_bump_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trip_checklists_bump_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trip_collaborators_bump_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END
$$;


ALTER FUNCTION "public"."trip_collaborators_bump_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trip_expenses_bump_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trip_expenses_bump_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trip_notes_bump_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trip_notes_bump_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."user_subscriptions_bump_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END
$$;


ALTER FUNCTION "public"."user_subscriptions_bump_updated_at"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."checklist_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "checklist_id" "uuid" NOT NULL,
    "trip_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "is_done" boolean DEFAULT false NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "due_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."checklist_items" OWNER TO "postgres";


COMMENT ON TABLE "public"."checklist_items" IS 'Rows in a trip checklist; trip_id denormalized for RLS.';



CREATE TABLE IF NOT EXISTS "public"."city_place_nearby_meals" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "city_profile_id" "uuid" NOT NULL,
    "activity_place_id" "text" NOT NULL,
    "restaurant_place_id" "text" NOT NULL,
    "distance_km" double precision NOT NULL,
    "walking_minutes_est" integer NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."city_place_nearby_meals" OWNER TO "postgres";


COMMENT ON TABLE "public"."city_place_nearby_meals" IS 'Precomputed pairs: non-restaurant activity place → nearby restaurant for a city profile.';



CREATE TABLE IF NOT EXISTS "public"."city_places" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "city_profile_id" "uuid" NOT NULL,
    "place_id" "text" NOT NULL,
    "name" "text" NOT NULL,
    "lat" double precision NOT NULL,
    "lng" double precision NOT NULL,
    "formatted_address" "text",
    "types" "text"[] DEFAULT '{}'::"text"[],
    "wayfind_category" "text" NOT NULL,
    "min_scope" "text" DEFAULT 'city_wide'::"text" NOT NULL,
    "tier" integer DEFAULT 2 NOT NULL,
    "source_query_count" integer DEFAULT 1 NOT NULL,
    "dist_from_center_km" double precision,
    "source_query" "text",
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "reported_count" integer DEFAULT 0 NOT NULL,
    "reported_at" timestamp with time zone,
    "last_refreshed_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "rating" double precision,
    "user_ratings_total" integer,
    "price_level" integer,
    "opening_hours" "jsonb",
    "details_enriched_at" timestamp with time zone,
    "ai_editorial_summary" "text",
    "ai_review_summary" "text",
    "ai_why_go" "text"[],
    "ai_know_before_you_go" "text"[],
    "ai_enriched_at" timestamp with time zone,
    "formatted_phone_number" "text",
    "international_phone_number" "text",
    "website" "text",
    "images" "jsonb",
    CONSTRAINT "city_places_min_scope_check" CHECK (("min_scope" = ANY (ARRAY['walkable'::"text", 'city_wide'::"text", 'spread_out'::"text"]))),
    CONSTRAINT "city_places_status_check" CHECK (("status" = ANY (ARRAY['active'::"text", 'reported'::"text", 'removed'::"text", 'stale'::"text"]))),
    CONSTRAINT "city_places_tier_check" CHECK ((("tier" >= 1) AND ("tier" <= 3))),
    CONSTRAINT "city_places_wayfind_category_check" CHECK (("wayfind_category" = ANY (ARRAY['attraction'::"text", 'restaurant'::"text", 'nature'::"text", 'shopping'::"text", 'nightlife'::"text", 'custom'::"text"])))
);


ALTER TABLE "public"."city_places" OWNER TO "postgres";


COMMENT ON TABLE "public"."city_places" IS 'Pre-fetched places pool per city for AI itinerary generation. Replaces runtime Google Places API calls. Seeded by batch script or auto-seed, refreshed every 30 days, cleaned by user reports.';



COMMENT ON COLUMN "public"."city_places"."details_enriched_at" IS 'When structured place details (rating, hours, phones, etc.) were last enriched.';



COMMENT ON COLUMN "public"."city_places"."ai_enriched_at" IS 'When AI summary fields were last successfully written.';



COMMENT ON COLUMN "public"."city_places"."images" IS 'Image metadata for the place (e.g. JSON array of photo URLs or Google-style photo objects).';



CREATE TABLE IF NOT EXISTS "public"."city_profiles" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "city_slug" "text" NOT NULL,
    "display_name" "text" NOT NULL,
    "country_code" "text" NOT NULL,
    "center_lat" double precision NOT NULL,
    "center_lng" double precision NOT NULL,
    "match_radius_km" double precision DEFAULT 50 NOT NULL,
    "city_search_label" "text" NOT NULL,
    "walkable_radius_m" integer DEFAULT 4000 NOT NULL,
    "city_wide_radius_m" integer DEFAULT 20000 NOT NULL,
    "spread_out_radius_m" integer DEFAULT 60000 NOT NULL,
    "walkable_dist_cap_km" double precision DEFAULT 5 NOT NULL,
    "city_wide_dist_cap_km" double precision DEFAULT 25 NOT NULL,
    "spread_out_dist_cap_km" double precision DEFAULT 60 NOT NULL,
    "cluster_radius_km" double precision DEFAULT 3 NOT NULL,
    "walkable_max_route_km" double precision DEFAULT 8 NOT NULL,
    "city_wide_max_route_km" double precision DEFAULT 35 NOT NULL,
    "spread_out_max_route_km" double precision DEFAULT 120 NOT NULL,
    "transit_note" "text",
    "neighborhoods" "text"[],
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."city_profiles" OWNER TO "postgres";


COMMENT ON TABLE "public"."city_profiles" IS 'Per-city tuning for AI itinerary generation: search radii, distance caps, route limits, and transit notes. Matched by geographic proximity to user base location.';



CREATE TABLE IF NOT EXISTS "public"."city_travel_times" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "city_profile_id" "uuid" NOT NULL,
    "from_place_id" "text" NOT NULL,
    "to_place_id" "text" NOT NULL,
    "walking_minutes" integer,
    "transit_minutes" integer,
    "driving_minutes" integer,
    "distance_meters" integer,
    "provider" "text" DEFAULT 'haversine'::"text" NOT NULL,
    "computed_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "city_travel_times_provider_check" CHECK (("provider" = ANY (ARRAY['mapbox'::"text", 'google'::"text", 'haversine'::"text"])))
);


ALTER TABLE "public"."city_travel_times" OWNER TO "postgres";


COMMENT ON TABLE "public"."city_travel_times" IS 'Cached travel times and distance between two place_ids within a city profile (routing / itinerary).';



CREATE TABLE IF NOT EXISTS "public"."collaboration_push_throttle" (
    "trip_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "last_push_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."collaboration_push_throttle" OWNER TO "postgres";


COMMENT ON TABLE "public"."collaboration_push_throttle" IS 'Stage 12: debounce batched trip-activity pushes (5 min window per recipient per trip).';



CREATE TABLE IF NOT EXISTS "public"."email_forwarding_queue" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "pipeline_debug" "jsonb" DEFAULT '{}'::"jsonb",
    "ingestion_stage" "text"
);


ALTER TABLE "public"."email_forwarding_queue" OWNER TO "postgres";


COMMENT ON COLUMN "public"."email_forwarding_queue"."pipeline_debug" IS 'Structured ingestion diagnostics (sizes, unwrap path). Not user-facing errors.';



COMMENT ON COLUMN "public"."email_forwarding_queue"."ingestion_stage" IS 'Last pipeline milestone for debugging (e.g. bodies_resolved, completed).';



CREATE TABLE IF NOT EXISTS "public"."feedback" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid",
    "category" "text" NOT NULL,
    "message" "text" NOT NULL,
    "app_version" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "feedback_category_check" CHECK (("category" = ANY (ARRAY['bug'::"text", 'feature'::"text", 'general'::"text", 'other'::"text"]))),
    CONSTRAINT "feedback_message_check" CHECK ((("char_length"("message") >= 10) AND ("char_length"("message") <= 2000)))
);


ALTER TABLE "public"."feedback" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."place_cache" (
    "place_id" "text" NOT NULL,
    "latitude" double precision,
    "longitude" double precision,
    "formatted_address" "text",
    "ai_editorial_summary" "text",
    "ai_review_summary" "text",
    "ai_why_go" "text"[],
    "ai_know_before_you_go" "text"[],
    "ai_enriched_at" timestamp with time zone
);


ALTER TABLE "public"."place_cache" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "preferred_airport" "text",
    "preferred_currency" "text"
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


COMMENT ON COLUMN "public"."profiles"."preferred_airport" IS 'Home or preferred airport (IATA or short label).';



COMMENT ON COLUMN "public"."profiles"."preferred_currency" IS 'Preferred ISO 4217 currency code (e.g. USD).';



CREATE TABLE IF NOT EXISTS "public"."trip_activities" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "trip_id" "uuid" NOT NULL,
    "day_id" "uuid",
    "user_id" "uuid",
    "name" "text",
    "description" "text",
    "category" "text",
    "starts_at" timestamp with time zone,
    "duration_minutes" integer,
    "latitude" double precision,
    "longitude" double precision,
    "address" "text",
    "place_id" "text",
    "estimated_cost" numeric,
    "currency" "text",
    "rating" real,
    "price_level" integer,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "travel_from_previous_minutes" integer,
    "directions_url" "text",
    "travel_mode" "text" DEFAULT 'driving'::"text" NOT NULL,
    "source" "text",
    "booking_id" "uuid",
    "hero_image_url" "text",
    "hero_attribution" "text",
    "place_search_query" "text",
    "meal_anchor" boolean DEFAULT false NOT NULL
);

ALTER TABLE ONLY "public"."trip_activities" REPLICA IDENTITY FULL;


ALTER TABLE "public"."trip_activities" OWNER TO "postgres";


COMMENT ON COLUMN "public"."trip_activities"."hero_image_url" IS 'Optional hero image URL for activity/place detail (e.g. Unsplash CDN).';



COMMENT ON COLUMN "public"."trip_activities"."hero_attribution" IS 'Attribution line for hero_image_url (e.g. Photo by … on Unsplash).';



COMMENT ON COLUMN "public"."trip_activities"."place_search_query" IS 'Optional text used to resolve lat/lng/place_id client-side after AI plan (no Google on plan path).';



COMMENT ON COLUMN "public"."trip_activities"."meal_anchor" IS 'When true, the route optimizer should not reorder this activity. Set by AI for meal stops that serve as geographic connectors between activity clusters.';



CREATE TABLE IF NOT EXISTS "public"."trip_activity_attachments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "activity_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "mime_type" "text",
    "attachment_type" "text",
    "is_cover" boolean DEFAULT false NOT NULL
);


ALTER TABLE "public"."trip_activity_attachments" OWNER TO "postgres";


COMMENT ON COLUMN "public"."trip_activity_attachments"."is_cover" IS 'Timeline cover; exactly one true per activity among image attachments (enforced in app).';



CREATE TABLE IF NOT EXISTS "public"."trip_activity_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "trip_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "action" "text" NOT NULL,
    "entity_type" "text",
    "entity_id" "uuid",
    "entity_name" "text",
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "trip_activity_log_action_check" CHECK (("action" = ANY (ARRAY['activity_added'::"text", 'activity_updated'::"text", 'activity_deleted'::"text", 'booking_added'::"text", 'booking_updated'::"text", 'booking_deleted'::"text", 'note_added'::"text", 'note_updated'::"text", 'checklist_added'::"text", 'checklist_item_toggled'::"text", 'day_reordered'::"text", 'collaborator_joined'::"text", 'collaborator_left'::"text", 'collaborator_role_changed'::"text", 'trip_updated'::"text", 'pending_invite_declined'::"text"])))
);

ALTER TABLE ONLY "public"."trip_activity_log" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."trip_activity_log" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."trip_bookings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "trip_id" "uuid" NOT NULL,
    "kind" "text" DEFAULT 'activity'::"text" NOT NULL,
    "user_id" "uuid"
);

ALTER TABLE ONLY "public"."trip_bookings" REPLICA IDENTITY FULL;


ALTER TABLE "public"."trip_bookings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."trip_checklists" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "trip_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "template_key" "text",
    CONSTRAINT "trip_checklists_template_key_check" CHECK ((("template_key" IS NULL) OR ("template_key" = ANY (ARRAY['packing'::"text", 'todo'::"text", 'documents'::"text", 'general'::"text"]))))
);


ALTER TABLE "public"."trip_checklists" OWNER TO "postgres";


COMMENT ON TABLE "public"."trip_checklists" IS 'Per-trip packing / to-do lists.';



COMMENT ON COLUMN "public"."trip_checklists"."template_key" IS 'Built-in checklist tab: packing | todo | documents | general. NULL = legacy user-created list.';



CREATE TABLE IF NOT EXISTS "public"."trip_collaborators" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "trip_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "role" "text" NOT NULL,
    "invited_email" "text",
    "status" "text" DEFAULT 'accepted'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "trip_collaborators_role_check" CHECK (("role" = ANY (ARRAY['editor'::"text", 'viewer'::"text"]))),
    CONSTRAINT "trip_collaborators_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'accepted'::"text", 'declined'::"text"])))
);

ALTER TABLE ONLY "public"."trip_collaborators" REPLICA IDENTITY FULL;

ALTER TABLE ONLY "public"."trip_collaborators" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."trip_collaborators" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."trip_days" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "trip_id" "uuid" NOT NULL,
    "date" "date" NOT NULL,
    "label" "text",
    "user_id" "uuid"
);

ALTER TABLE ONLY "public"."trip_days" REPLICA IDENTITY FULL;


ALTER TABLE "public"."trip_days" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."trip_documents" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "trip_id" "uuid" NOT NULL,
    "uploaded_by" "uuid" NOT NULL,
    "storage_path" "text" NOT NULL,
    "file_name" "text" NOT NULL,
    "mime_type" "text" NOT NULL,
    "byte_size" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "title" "text",
    CONSTRAINT "trip_documents_byte_size_check" CHECK (("byte_size" >= 0))
);


ALTER TABLE "public"."trip_documents" OWNER TO "postgres";


COMMENT ON TABLE "public"."trip_documents" IS 'Metadata for trip files in Storage bucket trip-documents under userId/trip-documents/tripId/.';



CREATE TABLE IF NOT EXISTS "public"."trip_expenses" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "trip_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "title" "text" DEFAULT ''::"text" NOT NULL,
    "amount" numeric(14,2) NOT NULL,
    "currency" "text" DEFAULT 'USD'::"text" NOT NULL,
    "category" "text",
    "spent_at" "date",
    "notes" "text",
    "payer_user_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "trip_expenses_amount_check" CHECK (("amount" >= (0)::numeric))
);


ALTER TABLE "public"."trip_expenses" OWNER TO "postgres";


COMMENT ON TABLE "public"."trip_expenses" IS 'Per-trip expense line items; currency per row; summary uses trip.budget_currency in app when matching.';



CREATE TABLE IF NOT EXISTS "public"."trip_invites" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "trip_id" "uuid" NOT NULL,
    "created_by" "uuid" NOT NULL,
    "token" "text" NOT NULL,
    "role" "text" NOT NULL,
    "max_uses" integer,
    "uses" integer DEFAULT 0 NOT NULL,
    "expires_at" timestamp with time zone DEFAULT ("now"() + '7 days'::interval),
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "invited_email" "text",
    CONSTRAINT "trip_invites_role_check" CHECK (("role" = ANY (ARRAY['editor'::"text", 'viewer'::"text"])))
);

ALTER TABLE ONLY "public"."trip_invites" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."trip_invites" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."trip_notes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "trip_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "title" "text" DEFAULT ''::"text" NOT NULL,
    "body" "text" DEFAULT ''::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."trip_notes" OWNER TO "postgres";


COMMENT ON TABLE "public"."trip_notes" IS 'Per-trip freeform notes; title + body, sorted by updated_at.';



CREATE TABLE IF NOT EXISTS "public"."trips" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "name" "text",
    "destination" "text",
    "start_date" "date",
    "end_date" "date",
    "display_timezone" "text"
);

ALTER TABLE ONLY "public"."trips" REPLICA IDENTITY FULL;


ALTER TABLE "public"."trips" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."usage_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "feature" "text" NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."usage_events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_subscriptions" (
    "user_id" "uuid" NOT NULL,
    "is_pro" boolean DEFAULT false NOT NULL,
    "plan_id" "text",
    "platform" "text",
    "original_transaction_id" "text",
    "expires_at" timestamp with time zone,
    "trial_used" boolean DEFAULT false NOT NULL,
    "is_in_billing_retry" boolean DEFAULT false NOT NULL,
    "validated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."user_subscriptions" OWNER TO "postgres";


ALTER TABLE ONLY "public"."checklist_items"
    ADD CONSTRAINT "checklist_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."city_place_nearby_meals"
    ADD CONSTRAINT "city_place_nearby_meals_city_profile_id_activity_place_id_r_key" UNIQUE ("city_profile_id", "activity_place_id", "restaurant_place_id");



ALTER TABLE ONLY "public"."city_place_nearby_meals"
    ADD CONSTRAINT "city_place_nearby_meals_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."city_places"
    ADD CONSTRAINT "city_places_city_profile_id_place_id_key" UNIQUE ("city_profile_id", "place_id");



ALTER TABLE ONLY "public"."city_places"
    ADD CONSTRAINT "city_places_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."city_profiles"
    ADD CONSTRAINT "city_profiles_city_slug_key" UNIQUE ("city_slug");



ALTER TABLE ONLY "public"."city_profiles"
    ADD CONSTRAINT "city_profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."city_travel_times"
    ADD CONSTRAINT "city_travel_times_city_profile_id_from_place_id_to_place_id_key" UNIQUE ("city_profile_id", "from_place_id", "to_place_id");



ALTER TABLE ONLY "public"."city_travel_times"
    ADD CONSTRAINT "city_travel_times_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."collaboration_push_throttle"
    ADD CONSTRAINT "collaboration_push_throttle_pkey" PRIMARY KEY ("trip_id", "user_id");



ALTER TABLE ONLY "public"."email_forwarding_queue"
    ADD CONSTRAINT "email_forwarding_queue_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."feedback"
    ADD CONSTRAINT "feedback_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."place_cache"
    ADD CONSTRAINT "place_cache_pkey" PRIMARY KEY ("place_id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."trip_activities"
    ADD CONSTRAINT "trip_activities_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."trip_activity_attachments"
    ADD CONSTRAINT "trip_activity_attachments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."trip_activity_log"
    ADD CONSTRAINT "trip_activity_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."trip_bookings"
    ADD CONSTRAINT "trip_bookings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."trip_checklists"
    ADD CONSTRAINT "trip_checklists_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."trip_collaborators"
    ADD CONSTRAINT "trip_collaborators_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."trip_collaborators"
    ADD CONSTRAINT "trip_collaborators_trip_id_user_id_key" UNIQUE ("trip_id", "user_id");



ALTER TABLE ONLY "public"."trip_days"
    ADD CONSTRAINT "trip_days_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."trip_documents"
    ADD CONSTRAINT "trip_documents_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."trip_documents"
    ADD CONSTRAINT "trip_documents_storage_path_key" UNIQUE ("storage_path");



ALTER TABLE ONLY "public"."trip_expenses"
    ADD CONSTRAINT "trip_expenses_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."trip_invites"
    ADD CONSTRAINT "trip_invites_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."trip_invites"
    ADD CONSTRAINT "trip_invites_token_unique" UNIQUE ("token");



ALTER TABLE ONLY "public"."trip_notes"
    ADD CONSTRAINT "trip_notes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."trips"
    ADD CONSTRAINT "trips_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."usage_events"
    ADD CONSTRAINT "usage_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_subscriptions"
    ADD CONSTRAINT "user_subscriptions_pkey" PRIMARY KEY ("user_id");



CREATE INDEX "checklist_items_checklist_sort_idx" ON "public"."checklist_items" USING "btree" ("checklist_id", "sort_order");



CREATE INDEX "checklist_items_trip_idx" ON "public"."checklist_items" USING "btree" ("trip_id");



CREATE INDEX "idx_city_places_query" ON "public"."city_places" USING "btree" ("city_profile_id", "status", "wayfind_category", "min_scope");



CREATE INDEX "idx_city_places_refresh" ON "public"."city_places" USING "btree" ("last_refreshed_at") WHERE ("status" = 'active'::"text");



CREATE INDEX "idx_city_profiles_geo" ON "public"."city_profiles" USING "btree" ("center_lat", "center_lng");



CREATE INDEX "idx_collaboration_push_throttle_user" ON "public"."collaboration_push_throttle" USING "btree" ("user_id");



CREATE INDEX "idx_nearby_meals_activity" ON "public"."city_place_nearby_meals" USING "btree" ("city_profile_id", "activity_place_id");



CREATE INDEX "idx_travel_times_lookup" ON "public"."city_travel_times" USING "btree" ("city_profile_id", "from_place_id", "to_place_id");



CREATE INDEX "idx_trip_activity_log_trip_created" ON "public"."trip_activity_log" USING "btree" ("trip_id", "created_at" DESC);



CREATE INDEX "idx_trip_collaborators_trip_id" ON "public"."trip_collaborators" USING "btree" ("trip_id");



CREATE INDEX "idx_trip_collaborators_user_id" ON "public"."trip_collaborators" USING "btree" ("user_id");



CREATE INDEX "idx_trip_invites_token" ON "public"."trip_invites" USING "btree" ("token");



CREATE INDEX "idx_trip_invites_trip_id" ON "public"."trip_invites" USING "btree" ("trip_id");



CREATE INDEX "idx_trip_invites_trip_invited_email" ON "public"."trip_invites" USING "btree" ("trip_id", "lower"(TRIM(BOTH FROM "invited_email"))) WHERE (("invited_email" IS NOT NULL) AND ("is_active" = true));



CREATE INDEX "idx_usage_events_user_feature_created_at" ON "public"."usage_events" USING "btree" ("user_id", "feature", "created_at" DESC);



CREATE INDEX "idx_user_subscriptions_expires_at" ON "public"."user_subscriptions" USING "btree" ("expires_at") WHERE ("is_pro" = true);



CREATE INDEX "trip_checklists_trip_sort_idx" ON "public"."trip_checklists" USING "btree" ("trip_id", "sort_order");



CREATE UNIQUE INDEX "trip_checklists_trip_template_key_uidx" ON "public"."trip_checklists" USING "btree" ("trip_id", "template_key") WHERE ("template_key" IS NOT NULL);



CREATE INDEX "trip_documents_trip_created_idx" ON "public"."trip_documents" USING "btree" ("trip_id", "created_at" DESC);



CREATE INDEX "trip_documents_uploaded_by_idx" ON "public"."trip_documents" USING "btree" ("uploaded_by");



CREATE INDEX "trip_expenses_trip_created_idx" ON "public"."trip_expenses" USING "btree" ("trip_id", "created_at" DESC);



CREATE INDEX "trip_expenses_trip_spent_idx" ON "public"."trip_expenses" USING "btree" ("trip_id", "spent_at" DESC NULLS LAST);



CREATE INDEX "trip_notes_trip_updated_idx" ON "public"."trip_notes" USING "btree" ("trip_id", "updated_at" DESC);



CREATE OR REPLACE TRIGGER "checklist_items_set_updated_at" BEFORE UPDATE ON "public"."checklist_items" FOR EACH ROW EXECUTE FUNCTION "public"."checklist_items_bump_updated_at"();



CREATE OR REPLACE TRIGGER "checklist_items_sync_trip_id_trigger" BEFORE INSERT OR UPDATE OF "checklist_id" ON "public"."checklist_items" FOR EACH ROW EXECUTE FUNCTION "public"."checklist_items_sync_trip_id"();



CREATE OR REPLACE TRIGGER "tr_trip_activity_attachments_max_photos" BEFORE INSERT ON "public"."trip_activity_attachments" FOR EACH ROW EXECUTE FUNCTION "public"."enforce_trip_activity_max_photos"();



CREATE OR REPLACE TRIGGER "trip_activities_log_collab" AFTER INSERT OR DELETE OR UPDATE ON "public"."trip_activities" FOR EACH ROW EXECUTE FUNCTION "public"."tg_log_trip_activity_changes"();



CREATE OR REPLACE TRIGGER "trip_bookings_log_collab" AFTER INSERT OR DELETE OR UPDATE ON "public"."trip_bookings" FOR EACH ROW EXECUTE FUNCTION "public"."tg_log_trip_booking_changes"();



CREATE OR REPLACE TRIGGER "trip_checklists_set_updated_at" BEFORE UPDATE ON "public"."trip_checklists" FOR EACH ROW EXECUTE FUNCTION "public"."trip_checklists_bump_updated_at"();



CREATE OR REPLACE TRIGGER "trip_collaborators_log_leave" AFTER DELETE ON "public"."trip_collaborators" FOR EACH ROW EXECUTE FUNCTION "public"."tg_log_trip_collaborator_leave"();



CREATE OR REPLACE TRIGGER "trip_collaborators_log_pending_decline" AFTER DELETE ON "public"."trip_collaborators" FOR EACH ROW EXECUTE FUNCTION "public"."tg_log_pending_invite_declined"();



CREATE OR REPLACE TRIGGER "trip_collaborators_log_role" AFTER UPDATE ON "public"."trip_collaborators" FOR EACH ROW EXECUTE FUNCTION "public"."tg_log_trip_collaborator_role"();



CREATE OR REPLACE TRIGGER "trip_collaborators_set_updated_at" BEFORE UPDATE ON "public"."trip_collaborators" FOR EACH ROW EXECUTE FUNCTION "public"."trip_collaborators_bump_updated_at"();



CREATE OR REPLACE TRIGGER "trip_expenses_set_updated_at" BEFORE UPDATE ON "public"."trip_expenses" FOR EACH ROW EXECUTE FUNCTION "public"."trip_expenses_bump_updated_at"();



CREATE OR REPLACE TRIGGER "trip_notes_set_updated_at" BEFORE UPDATE ON "public"."trip_notes" FOR EACH ROW EXECUTE FUNCTION "public"."trip_notes_bump_updated_at"();



CREATE OR REPLACE TRIGGER "trips_log_updated" AFTER UPDATE ON "public"."trips" FOR EACH ROW EXECUTE FUNCTION "public"."tg_log_trip_updated"();



CREATE OR REPLACE TRIGGER "user_subscriptions_set_updated_at" BEFORE UPDATE ON "public"."user_subscriptions" FOR EACH ROW EXECUTE FUNCTION "public"."user_subscriptions_bump_updated_at"();



ALTER TABLE ONLY "public"."checklist_items"
    ADD CONSTRAINT "checklist_items_checklist_id_fkey" FOREIGN KEY ("checklist_id") REFERENCES "public"."trip_checklists"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."checklist_items"
    ADD CONSTRAINT "checklist_items_trip_id_fkey" FOREIGN KEY ("trip_id") REFERENCES "public"."trips"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."checklist_items"
    ADD CONSTRAINT "checklist_items_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."city_place_nearby_meals"
    ADD CONSTRAINT "city_place_nearby_meals_city_profile_id_fkey" FOREIGN KEY ("city_profile_id") REFERENCES "public"."city_profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."city_places"
    ADD CONSTRAINT "city_places_city_profile_id_fkey" FOREIGN KEY ("city_profile_id") REFERENCES "public"."city_profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."city_travel_times"
    ADD CONSTRAINT "city_travel_times_city_profile_id_fkey" FOREIGN KEY ("city_profile_id") REFERENCES "public"."city_profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."collaboration_push_throttle"
    ADD CONSTRAINT "collaboration_push_throttle_trip_id_fkey" FOREIGN KEY ("trip_id") REFERENCES "public"."trips"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."feedback"
    ADD CONSTRAINT "feedback_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_activities"
    ADD CONSTRAINT "trip_activities_day_id_fkey" FOREIGN KEY ("day_id") REFERENCES "public"."trip_days"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."trip_activities"
    ADD CONSTRAINT "trip_activities_trip_id_fkey" FOREIGN KEY ("trip_id") REFERENCES "public"."trips"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_activities"
    ADD CONSTRAINT "trip_activities_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."trip_activity_attachments"
    ADD CONSTRAINT "trip_activity_attachments_activity_id_fkey" FOREIGN KEY ("activity_id") REFERENCES "public"."trip_activities"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_activity_log"
    ADD CONSTRAINT "trip_activity_log_trip_id_fkey" FOREIGN KEY ("trip_id") REFERENCES "public"."trips"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_activity_log"
    ADD CONSTRAINT "trip_activity_log_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."trip_bookings"
    ADD CONSTRAINT "trip_bookings_trip_id_fkey" FOREIGN KEY ("trip_id") REFERENCES "public"."trips"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_bookings"
    ADD CONSTRAINT "trip_bookings_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."trip_checklists"
    ADD CONSTRAINT "trip_checklists_trip_id_fkey" FOREIGN KEY ("trip_id") REFERENCES "public"."trips"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_checklists"
    ADD CONSTRAINT "trip_checklists_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_collaborators"
    ADD CONSTRAINT "trip_collaborators_trip_id_fkey" FOREIGN KEY ("trip_id") REFERENCES "public"."trips"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_collaborators"
    ADD CONSTRAINT "trip_collaborators_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_days"
    ADD CONSTRAINT "trip_days_trip_id_fkey" FOREIGN KEY ("trip_id") REFERENCES "public"."trips"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_days"
    ADD CONSTRAINT "trip_days_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_documents"
    ADD CONSTRAINT "trip_documents_trip_id_fkey" FOREIGN KEY ("trip_id") REFERENCES "public"."trips"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_documents"
    ADD CONSTRAINT "trip_documents_uploaded_by_fkey" FOREIGN KEY ("uploaded_by") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_expenses"
    ADD CONSTRAINT "trip_expenses_payer_user_id_fkey" FOREIGN KEY ("payer_user_id") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."trip_expenses"
    ADD CONSTRAINT "trip_expenses_trip_id_fkey" FOREIGN KEY ("trip_id") REFERENCES "public"."trips"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_expenses"
    ADD CONSTRAINT "trip_expenses_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_invites"
    ADD CONSTRAINT "trip_invites_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."trip_invites"
    ADD CONSTRAINT "trip_invites_trip_id_fkey" FOREIGN KEY ("trip_id") REFERENCES "public"."trips"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_notes"
    ADD CONSTRAINT "trip_notes_trip_id_fkey" FOREIGN KEY ("trip_id") REFERENCES "public"."trips"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_notes"
    ADD CONSTRAINT "trip_notes_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trips"
    ADD CONSTRAINT "trips_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."usage_events"
    ADD CONSTRAINT "usage_events_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_subscriptions"
    ADD CONSTRAINT "user_subscriptions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



CREATE POLICY "Users can submit feedback" ON "public"."feedback" FOR INSERT TO "authenticated" WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can view own feedback" ON "public"."feedback" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



ALTER TABLE "public"."checklist_items" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "checklist_items_delete_editors" ON "public"."checklist_items" FOR DELETE TO "authenticated" USING ("public"."can_edit_trip"("trip_id"));



CREATE POLICY "checklist_items_insert_editors" ON "public"."checklist_items" FOR INSERT TO "authenticated" WITH CHECK (("public"."can_edit_trip"("trip_id") AND ("user_id" = ( SELECT "auth"."uid"() AS "uid"))));



CREATE POLICY "checklist_items_select_viewers" ON "public"."checklist_items" FOR SELECT TO "authenticated" USING ("public"."can_view_trip"("trip_id"));



CREATE POLICY "checklist_items_update_editors" ON "public"."checklist_items" FOR UPDATE TO "authenticated" USING ("public"."can_edit_trip"("trip_id")) WITH CHECK ("public"."can_edit_trip"("trip_id"));



ALTER TABLE "public"."city_place_nearby_meals" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."city_places" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "city_places_public_read" ON "public"."city_places" FOR SELECT USING (true);



ALTER TABLE "public"."city_profiles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "city_profiles_public_read" ON "public"."city_profiles" FOR SELECT USING (true);



ALTER TABLE "public"."city_travel_times" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."collaboration_push_throttle" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."feedback" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "nearby_meals_public_read" ON "public"."city_place_nearby_meals" FOR SELECT USING (true);



CREATE POLICY "travel_times_public_read" ON "public"."city_travel_times" FOR SELECT USING (true);



CREATE POLICY "trip_activities_delete_collaborator" ON "public"."trip_activities" FOR DELETE TO "authenticated" USING ("public"."can_edit_trip"("trip_id"));



CREATE POLICY "trip_activities_insert_collaborator" ON "public"."trip_activities" FOR INSERT TO "authenticated" WITH CHECK ("public"."can_edit_trip"("trip_id"));



CREATE POLICY "trip_activities_select_collaborator" ON "public"."trip_activities" FOR SELECT TO "authenticated" USING ("public"."can_view_trip"("trip_id"));



CREATE POLICY "trip_activities_update_collaborator" ON "public"."trip_activities" FOR UPDATE TO "authenticated" USING ("public"."can_edit_trip"("trip_id")) WITH CHECK ("public"."can_edit_trip"("trip_id"));



ALTER TABLE "public"."trip_activity_log" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "trip_activity_log_select" ON "public"."trip_activity_log" FOR SELECT TO "authenticated" USING ("public"."can_view_trip"("trip_id"));



CREATE POLICY "trip_bookings_delete_collaborator" ON "public"."trip_bookings" FOR DELETE TO "authenticated" USING ("public"."can_edit_trip"("trip_id"));



CREATE POLICY "trip_bookings_insert_collaborator" ON "public"."trip_bookings" FOR INSERT TO "authenticated" WITH CHECK ("public"."can_edit_trip"("trip_id"));



CREATE POLICY "trip_bookings_select_collaborator" ON "public"."trip_bookings" FOR SELECT TO "authenticated" USING ("public"."can_view_trip"("trip_id"));



CREATE POLICY "trip_bookings_update_collaborator" ON "public"."trip_bookings" FOR UPDATE TO "authenticated" USING ("public"."can_edit_trip"("trip_id")) WITH CHECK ("public"."can_edit_trip"("trip_id"));



ALTER TABLE "public"."trip_checklists" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "trip_checklists_delete_editors" ON "public"."trip_checklists" FOR DELETE TO "authenticated" USING ("public"."can_edit_trip"("trip_id"));



CREATE POLICY "trip_checklists_insert_editors" ON "public"."trip_checklists" FOR INSERT TO "authenticated" WITH CHECK (("public"."can_edit_trip"("trip_id") AND ("user_id" = ( SELECT "auth"."uid"() AS "uid"))));



CREATE POLICY "trip_checklists_select_viewers" ON "public"."trip_checklists" FOR SELECT TO "authenticated" USING ("public"."can_view_trip"("trip_id"));



CREATE POLICY "trip_checklists_update_editors" ON "public"."trip_checklists" FOR UPDATE TO "authenticated" USING ("public"."can_edit_trip"("trip_id")) WITH CHECK ("public"."can_edit_trip"("trip_id"));



ALTER TABLE "public"."trip_collaborators" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "trip_collaborators_delete_owner_or_self" ON "public"."trip_collaborators" FOR DELETE TO "authenticated" USING (("public"."is_trip_owner"("trip_id") OR (("user_id" = ( SELECT "auth"."uid"() AS "uid")) AND ("status" = 'accepted'::"text")) OR (("user_id" = ( SELECT "auth"."uid"() AS "uid")) AND ("status" = 'pending'::"text"))));



CREATE POLICY "trip_collaborators_insert_owner" ON "public"."trip_collaborators" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_trip_owner"("trip_id"));



CREATE POLICY "trip_collaborators_select" ON "public"."trip_collaborators" FOR SELECT TO "authenticated" USING ("public"."can_view_trip"("trip_id"));



CREATE POLICY "trip_collaborators_update_owner" ON "public"."trip_collaborators" FOR UPDATE TO "authenticated" USING ("public"."is_trip_owner"("trip_id")) WITH CHECK ("public"."is_trip_owner"("trip_id"));



CREATE POLICY "trip_days_delete_collaborator" ON "public"."trip_days" FOR DELETE TO "authenticated" USING ("public"."can_edit_trip"("trip_id"));



CREATE POLICY "trip_days_insert_collaborator" ON "public"."trip_days" FOR INSERT TO "authenticated" WITH CHECK ("public"."can_edit_trip"("trip_id"));



CREATE POLICY "trip_days_select_collaborator" ON "public"."trip_days" FOR SELECT TO "authenticated" USING ("public"."can_view_trip"("trip_id"));



CREATE POLICY "trip_days_update_collaborator" ON "public"."trip_days" FOR UPDATE TO "authenticated" USING ("public"."can_edit_trip"("trip_id")) WITH CHECK ("public"."can_edit_trip"("trip_id"));



ALTER TABLE "public"."trip_documents" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "trip_documents_delete_editors" ON "public"."trip_documents" FOR DELETE TO "authenticated" USING ("public"."can_edit_trip"("trip_id"));



CREATE POLICY "trip_documents_insert_editors" ON "public"."trip_documents" FOR INSERT TO "authenticated" WITH CHECK (("public"."can_edit_trip"("trip_id") AND ("uploaded_by" = ( SELECT "auth"."uid"() AS "uid"))));



CREATE POLICY "trip_documents_select_viewers" ON "public"."trip_documents" FOR SELECT TO "authenticated" USING ("public"."can_view_trip"("trip_id"));



CREATE POLICY "trip_documents_update_editors" ON "public"."trip_documents" FOR UPDATE TO "authenticated" USING ("public"."can_edit_trip"("trip_id")) WITH CHECK ("public"."can_edit_trip"("trip_id"));



ALTER TABLE "public"."trip_expenses" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "trip_expenses_delete_editors" ON "public"."trip_expenses" FOR DELETE TO "authenticated" USING ("public"."can_edit_trip"("trip_id"));



CREATE POLICY "trip_expenses_insert_editors" ON "public"."trip_expenses" FOR INSERT TO "authenticated" WITH CHECK (("public"."can_edit_trip"("trip_id") AND ("user_id" = ( SELECT "auth"."uid"() AS "uid"))));



CREATE POLICY "trip_expenses_select_viewers" ON "public"."trip_expenses" FOR SELECT TO "authenticated" USING ("public"."can_view_trip"("trip_id"));



CREATE POLICY "trip_expenses_update_editors" ON "public"."trip_expenses" FOR UPDATE TO "authenticated" USING ("public"."can_edit_trip"("trip_id")) WITH CHECK ("public"."can_edit_trip"("trip_id"));



ALTER TABLE "public"."trip_invites" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "trip_invites_delete_owner" ON "public"."trip_invites" FOR DELETE TO "authenticated" USING ("public"."is_trip_owner"("trip_id"));



CREATE POLICY "trip_invites_insert_owner" ON "public"."trip_invites" FOR INSERT TO "authenticated" WITH CHECK (("public"."is_trip_owner"("trip_id") AND ("created_by" = ( SELECT "auth"."uid"() AS "uid"))));



CREATE POLICY "trip_invites_select_owner" ON "public"."trip_invites" FOR SELECT TO "authenticated" USING ("public"."is_trip_owner"("trip_id"));



CREATE POLICY "trip_invites_update_owner" ON "public"."trip_invites" FOR UPDATE TO "authenticated" USING ("public"."is_trip_owner"("trip_id")) WITH CHECK ("public"."is_trip_owner"("trip_id"));



ALTER TABLE "public"."trip_notes" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "trip_notes_delete_editors" ON "public"."trip_notes" FOR DELETE TO "authenticated" USING ("public"."can_edit_trip"("trip_id"));



CREATE POLICY "trip_notes_insert_editors" ON "public"."trip_notes" FOR INSERT TO "authenticated" WITH CHECK (("public"."can_edit_trip"("trip_id") AND ("user_id" = ( SELECT "auth"."uid"() AS "uid"))));



CREATE POLICY "trip_notes_select_viewers" ON "public"."trip_notes" FOR SELECT TO "authenticated" USING ("public"."can_view_trip"("trip_id"));



CREATE POLICY "trip_notes_update_editors" ON "public"."trip_notes" FOR UPDATE TO "authenticated" USING ("public"."can_edit_trip"("trip_id")) WITH CHECK ("public"."can_edit_trip"("trip_id"));



CREATE POLICY "trips_select_collaborator" ON "public"."trips" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."trip_collaborators" "tc"
  WHERE (("tc"."trip_id" = "trips"."id") AND ("tc"."user_id" = ( SELECT "auth"."uid"() AS "uid")) AND ("tc"."status" = 'accepted'::"text")))));



CREATE POLICY "trips_update_can_edit" ON "public"."trips" FOR UPDATE TO "authenticated" USING ("public"."can_edit_trip"("id")) WITH CHECK ("public"."can_edit_trip"("id"));



ALTER TABLE "public"."usage_events" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "usage_events_insert_own" ON "public"."usage_events" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "usage_events_select_own" ON "public"."usage_events" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));



ALTER TABLE "public"."user_subscriptions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "user_subscriptions_select_own" ON "public"."user_subscriptions" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));



GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



REVOKE ALL ON FUNCTION "public"."accept_invite"("invite_token" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."accept_invite"("invite_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."accept_invite"("invite_token" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."accept_invite"("invite_token" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."accept_pending_collaborator"("p_trip_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."accept_pending_collaborator"("p_trip_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."accept_pending_collaborator"("p_trip_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."accept_pending_collaborator"("p_trip_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."apply_itinerary_ops"("p_trip_id" "uuid", "p_actor_id" "uuid", "p_payload" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."apply_itinerary_ops"("p_trip_id" "uuid", "p_actor_id" "uuid", "p_payload" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."apply_itinerary_ops"("p_trip_id" "uuid", "p_actor_id" "uuid", "p_payload" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."apply_itinerary_ops"("p_trip_id" "uuid", "p_actor_id" "uuid", "p_payload" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."can_edit_trip"("p_trip_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."can_edit_trip"("p_trip_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."can_edit_trip"("p_trip_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."can_edit_trip"("p_trip_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."can_view_trip"("p_trip_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."can_view_trip"("p_trip_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."can_view_trip"("p_trip_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."can_view_trip"("p_trip_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."checklist_items_bump_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."checklist_items_bump_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."checklist_items_bump_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."checklist_items_sync_trip_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."checklist_items_sync_trip_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."checklist_items_sync_trip_id"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."claim_ai_usage"("p_user_id" "uuid", "p_feature" "text", "p_monthly_limit" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."claim_ai_usage"("p_user_id" "uuid", "p_feature" "text", "p_monthly_limit" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."claim_ai_usage"("p_user_id" "uuid", "p_feature" "text", "p_monthly_limit" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."claim_ai_usage"("p_user_id" "uuid", "p_feature" "text", "p_monthly_limit" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."enforce_trip_activity_max_photos"() TO "anon";
GRANT ALL ON FUNCTION "public"."enforce_trip_activity_max_photos"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."enforce_trip_activity_max_photos"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."ensure_trip_checklist_templates"("p_trip_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."ensure_trip_checklist_templates"("p_trip_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."ensure_trip_checklist_templates"("p_trip_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ensure_trip_checklist_templates"("p_trip_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_invite_preview"("invite_token" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_invite_preview"("invite_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_invite_preview"("invite_token" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_invite_preview"("invite_token" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_trip_owner_profile_snippet"("p_trip_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_trip_owner_profile_snippet"("p_trip_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_trip_owner_profile_snippet"("p_trip_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_trip_owner_profile_snippet"("p_trip_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."is_trip_editor"("p_trip_id" "uuid", "p_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."is_trip_editor"("p_trip_id" "uuid", "p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_trip_editor"("p_trip_id" "uuid", "p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_trip_editor"("p_trip_id" "uuid", "p_user_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."is_trip_member"("p_trip_id" "uuid", "p_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."is_trip_member"("p_trip_id" "uuid", "p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_trip_member"("p_trip_id" "uuid", "p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_trip_member"("p_trip_id" "uuid", "p_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."is_trip_owner"("p_trip_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_trip_owner"("p_trip_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_trip_owner"("p_trip_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."list_trip_collaborator_profile_snippets"("p_trip_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."list_trip_collaborator_profile_snippets"("p_trip_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."list_trip_collaborator_profile_snippets"("p_trip_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."list_trip_collaborator_profile_snippets"("p_trip_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."lookup_auth_user_id_by_email"("p_email" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."lookup_auth_user_id_by_email"("p_email" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."lookup_auth_user_id_by_email"("p_email" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."lookup_auth_user_id_by_email"("p_email" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."tg_log_pending_invite_declined"() TO "anon";
GRANT ALL ON FUNCTION "public"."tg_log_pending_invite_declined"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."tg_log_pending_invite_declined"() TO "service_role";



GRANT ALL ON FUNCTION "public"."tg_log_trip_activity_changes"() TO "anon";
GRANT ALL ON FUNCTION "public"."tg_log_trip_activity_changes"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."tg_log_trip_activity_changes"() TO "service_role";



GRANT ALL ON FUNCTION "public"."tg_log_trip_booking_changes"() TO "anon";
GRANT ALL ON FUNCTION "public"."tg_log_trip_booking_changes"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."tg_log_trip_booking_changes"() TO "service_role";



GRANT ALL ON FUNCTION "public"."tg_log_trip_collaborator_leave"() TO "anon";
GRANT ALL ON FUNCTION "public"."tg_log_trip_collaborator_leave"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."tg_log_trip_collaborator_leave"() TO "service_role";



GRANT ALL ON FUNCTION "public"."tg_log_trip_collaborator_role"() TO "anon";
GRANT ALL ON FUNCTION "public"."tg_log_trip_collaborator_role"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."tg_log_trip_collaborator_role"() TO "service_role";



GRANT ALL ON FUNCTION "public"."tg_log_trip_updated"() TO "anon";
GRANT ALL ON FUNCTION "public"."tg_log_trip_updated"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."tg_log_trip_updated"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trip_checklists_bump_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."trip_checklists_bump_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trip_checklists_bump_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trip_collaborators_bump_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."trip_collaborators_bump_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trip_collaborators_bump_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trip_expenses_bump_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."trip_expenses_bump_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trip_expenses_bump_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trip_notes_bump_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."trip_notes_bump_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trip_notes_bump_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."user_subscriptions_bump_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."user_subscriptions_bump_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."user_subscriptions_bump_updated_at"() TO "service_role";



GRANT ALL ON TABLE "public"."checklist_items" TO "anon";
GRANT ALL ON TABLE "public"."checklist_items" TO "authenticated";
GRANT ALL ON TABLE "public"."checklist_items" TO "service_role";



GRANT ALL ON TABLE "public"."city_place_nearby_meals" TO "anon";
GRANT ALL ON TABLE "public"."city_place_nearby_meals" TO "authenticated";
GRANT ALL ON TABLE "public"."city_place_nearby_meals" TO "service_role";



GRANT ALL ON TABLE "public"."city_places" TO "anon";
GRANT ALL ON TABLE "public"."city_places" TO "authenticated";
GRANT ALL ON TABLE "public"."city_places" TO "service_role";



GRANT ALL ON TABLE "public"."city_profiles" TO "anon";
GRANT ALL ON TABLE "public"."city_profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."city_profiles" TO "service_role";



GRANT ALL ON TABLE "public"."city_travel_times" TO "anon";
GRANT ALL ON TABLE "public"."city_travel_times" TO "authenticated";
GRANT ALL ON TABLE "public"."city_travel_times" TO "service_role";



GRANT ALL ON TABLE "public"."collaboration_push_throttle" TO "anon";
GRANT ALL ON TABLE "public"."collaboration_push_throttle" TO "authenticated";
GRANT ALL ON TABLE "public"."collaboration_push_throttle" TO "service_role";



GRANT ALL ON TABLE "public"."email_forwarding_queue" TO "anon";
GRANT ALL ON TABLE "public"."email_forwarding_queue" TO "authenticated";
GRANT ALL ON TABLE "public"."email_forwarding_queue" TO "service_role";



GRANT ALL ON TABLE "public"."feedback" TO "anon";
GRANT ALL ON TABLE "public"."feedback" TO "authenticated";
GRANT ALL ON TABLE "public"."feedback" TO "service_role";



GRANT ALL ON TABLE "public"."place_cache" TO "anon";
GRANT ALL ON TABLE "public"."place_cache" TO "authenticated";
GRANT ALL ON TABLE "public"."place_cache" TO "service_role";



GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT ALL ON TABLE "public"."trip_activities" TO "anon";
GRANT ALL ON TABLE "public"."trip_activities" TO "authenticated";
GRANT ALL ON TABLE "public"."trip_activities" TO "service_role";



GRANT ALL ON TABLE "public"."trip_activity_attachments" TO "anon";
GRANT ALL ON TABLE "public"."trip_activity_attachments" TO "authenticated";
GRANT ALL ON TABLE "public"."trip_activity_attachments" TO "service_role";



GRANT ALL ON TABLE "public"."trip_activity_log" TO "anon";
GRANT ALL ON TABLE "public"."trip_activity_log" TO "authenticated";
GRANT ALL ON TABLE "public"."trip_activity_log" TO "service_role";



GRANT ALL ON TABLE "public"."trip_bookings" TO "anon";
GRANT ALL ON TABLE "public"."trip_bookings" TO "authenticated";
GRANT ALL ON TABLE "public"."trip_bookings" TO "service_role";



GRANT ALL ON TABLE "public"."trip_checklists" TO "anon";
GRANT ALL ON TABLE "public"."trip_checklists" TO "authenticated";
GRANT ALL ON TABLE "public"."trip_checklists" TO "service_role";



GRANT ALL ON TABLE "public"."trip_collaborators" TO "anon";
GRANT ALL ON TABLE "public"."trip_collaborators" TO "authenticated";
GRANT ALL ON TABLE "public"."trip_collaborators" TO "service_role";



GRANT ALL ON TABLE "public"."trip_days" TO "anon";
GRANT ALL ON TABLE "public"."trip_days" TO "authenticated";
GRANT ALL ON TABLE "public"."trip_days" TO "service_role";



GRANT ALL ON TABLE "public"."trip_documents" TO "anon";
GRANT ALL ON TABLE "public"."trip_documents" TO "authenticated";
GRANT ALL ON TABLE "public"."trip_documents" TO "service_role";



GRANT ALL ON TABLE "public"."trip_expenses" TO "anon";
GRANT ALL ON TABLE "public"."trip_expenses" TO "authenticated";
GRANT ALL ON TABLE "public"."trip_expenses" TO "service_role";



GRANT ALL ON TABLE "public"."trip_invites" TO "anon";
GRANT ALL ON TABLE "public"."trip_invites" TO "authenticated";
GRANT ALL ON TABLE "public"."trip_invites" TO "service_role";



GRANT ALL ON TABLE "public"."trip_notes" TO "anon";
GRANT ALL ON TABLE "public"."trip_notes" TO "authenticated";
GRANT ALL ON TABLE "public"."trip_notes" TO "service_role";



GRANT ALL ON TABLE "public"."trips" TO "anon";
GRANT ALL ON TABLE "public"."trips" TO "authenticated";
GRANT ALL ON TABLE "public"."trips" TO "service_role";



GRANT ALL ON TABLE "public"."usage_events" TO "anon";
GRANT ALL ON TABLE "public"."usage_events" TO "authenticated";
GRANT ALL ON TABLE "public"."usage_events" TO "service_role";



GRANT ALL ON TABLE "public"."user_subscriptions" TO "anon";
GRANT ALL ON TABLE "public"."user_subscriptions" TO "authenticated";
GRANT ALL ON TABLE "public"."user_subscriptions" TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";







