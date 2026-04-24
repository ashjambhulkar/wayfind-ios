


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


CREATE OR REPLACE FUNCTION "public"."current_user_is_trip_editor"("p_trip_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select public.is_trip_editor(p_trip_id, auth.uid());
$$;


ALTER FUNCTION "public"."current_user_is_trip_editor"("p_trip_id" "uuid") OWNER TO "postgres";


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


CREATE OR REPLACE FUNCTION "public"."handle_new_profile"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  insert into public.user_stats (user_id) values (new.id);
  return new;
end;
$$;


ALTER FUNCTION "public"."handle_new_profile"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  insert into public.profiles (id, username, display_name)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'username', split_part(new.email, '@', 1)),
    coalesce(new.raw_user_meta_data->>'display_name', split_part(new.email, '@', 1))
  );
  return new;
end;
$$;


ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_pins_change"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  affected_uid uuid;
begin
  affected_uid := case TG_OP when 'DELETE' then old.user_id else new.user_id end;
  perform public.recalculate_user_stats(affected_uid);
  return null;
end;
$$;


ALTER FUNCTION "public"."handle_pins_change"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_trips_change"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  affected_uid uuid;
begin
  affected_uid := case TG_OP when 'DELETE' then old.user_id else new.user_id end;
  perform public.recalculate_user_stats(affected_uid);
  return null;
end;
$$;


ALTER FUNCTION "public"."handle_trips_change"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  new.updated_at = now();
  return new;
end;
$$;


ALTER FUNCTION "public"."handle_updated_at"() OWNER TO "postgres";


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


CREATE OR REPLACE FUNCTION "public"."is_trip_owner"("p_trip_id" "uuid", "p_user_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (
    select 1 from public.trips t
    where t.id = p_trip_id and t.user_id = p_user_id
  );
$$;


ALTER FUNCTION "public"."is_trip_owner"("p_trip_id" "uuid", "p_user_id" "uuid") OWNER TO "postgres";


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


CREATE OR REPLACE FUNCTION "public"."notify_todays_bookings"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  r record;
begin
  for r in
    select b.id as booking_id, b.title, b.kind, b.user_id,
           t.id as trip_id, t.name as trip_name
    from trip_bookings b
    join trips t on t.id = b.trip_id
    where b.starts_at::date = current_date
  loop
    perform send_push_notification(
      r.user_id,
      'booking_reminder',
      'Booking today',
      r.title || ' is today (' || r.trip_name || ').',
      jsonb_build_object('tripId', r.trip_id, 'bookingId', r.booking_id),
      'booking_reminder:' || r.booking_id || ':' || current_date
    );
  end loop;
end;
$$;


ALTER FUNCTION "public"."notify_todays_bookings"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."notify_upcoming_trips"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  r record;
begin
  for r in
    select t.id as trip_id, t.user_id, t.name as trip_name
    from trips t
    where t.start_date = current_date + 1
      and t.status = 'planned'
  loop
    perform send_push_notification(
      r.user_id,
      'trip_reminder',
      'Trip starts tomorrow',
      'Your trip "' || r.trip_name || '" starts tomorrow. Have a great time!',
      jsonb_build_object('tripId', r.trip_id),
      'trip_reminder:' || r.trip_id || ':' || current_date
    );
  end loop;

  for r in
    select tc.collaborator_id as user_id, t.id as trip_id, t.name as trip_name
    from trips t
    join trip_collaborators tc on tc.trip_id = t.id
    where t.start_date = current_date + 1
      and t.status = 'planned'
      and tc.status = 'accepted'
  loop
    perform send_push_notification(
      r.user_id,
      'trip_reminder',
      'Trip starts tomorrow',
      'The trip "' || r.trip_name || '" starts tomorrow. Have a great time!',
      jsonb_build_object('tripId', r.trip_id),
      'trip_reminder:' || r.trip_id || ':' || r.user_id || ':' || current_date
    );
  end loop;
end;
$$;


ALTER FUNCTION "public"."notify_upcoming_trips"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."recalculate_user_stats"("uid" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  insert into public.user_stats (
    user_id,
    countries_visited,
    total_trips,
    total_distance_km,
    total_pins,
    updated_at
  )
  values (
    uid,
    (select count(distinct country_code)
       from public.pins
      where user_id = uid and country_code is not null),
    (select count(*) from public.trips where user_id = uid),
    0,  -- distance is tracked separately via trip routes
    (select count(*) from public.pins where user_id = uid),
    now()
  )
  on conflict (user_id) do update set
    countries_visited = excluded.countries_visited,
    total_trips       = excluded.total_trips,
    total_distance_km = excluded.total_distance_km,
    total_pins        = excluded.total_pins,
    updated_at        = excluded.updated_at;
end;
$$;


ALTER FUNCTION "public"."recalculate_user_stats"("uid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."send_push_notification"("p_user_id" "uuid", "p_type" "text", "p_title" "text", "p_body" "text", "p_data" "jsonb" DEFAULT '{}'::"jsonb", "p_idempotency" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_url  text;
  v_key  text;
  v_body jsonb;
begin
  v_url := current_setting('app.settings.supabase_url', true)
           || '/functions/v1/send-notification';
  v_key := current_setting('app.settings.service_role_key', true);

  if v_url is null or v_url = '' then
    v_url := (select decrypted_secret from vault.decrypted_secrets where name = 'supabase_url' limit 1)
             || '/functions/v1/send-notification';
  end if;
  if v_key is null or v_key = '' then
    v_key := (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key' limit 1);
  end if;

  v_body := jsonb_build_object(
    'userId', p_user_id,
    'type', p_type,
    'title', p_title,
    'body', p_body,
    'data', p_data
  );
  if p_idempotency is not null then
    v_body := v_body || jsonb_build_object('idempotencyKey', p_idempotency);
  end if;

  perform net.http_post(
    url     := v_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_key
    ),
    body    := v_body
  );
end;
$$;


ALTER FUNCTION "public"."send_push_notification"("p_user_id" "uuid", "p_type" "text", "p_title" "text", "p_body" "text", "p_data" "jsonb", "p_idempotency" "text") OWNER TO "postgres";


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


CREATE OR REPLACE FUNCTION "public"."trips_prevent_collaborator_rename"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if auth.uid() is distinct from new.user_id
     and new.name is distinct from old.name then
    raise exception 'ONLY_OWNER_CAN_RENAME_TRIP'
      using errcode = 'P0001',
            message = 'Only the trip owner can change the trip name';
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."trips_prevent_collaborator_rename"() OWNER TO "postgres";


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
    "user_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "is_done" boolean DEFAULT false NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "trip_id" "uuid" NOT NULL
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
    "user_id" "uuid",
    "trip_id" "uuid",
    "sender_email" "text" NOT NULL,
    "subject" "text",
    "message_id_hash" "text" NOT NULL,
    "raw_email_storage_path" "text",
    "extracted_bookings" "jsonb",
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "error_message" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "processed_at" timestamp with time zone,
    "pipeline_debug" "jsonb" DEFAULT '{}'::"jsonb",
    "ingestion_stage" "text",
    CONSTRAINT "email_forwarding_queue_status_check" CHECK (("status" = ANY (ARRAY['received'::"text", 'pending'::"text", 'processing'::"text", 'processed'::"text", 'failed'::"text", 'no_user'::"text", 'needs_assignment'::"text"])))
);


ALTER TABLE "public"."email_forwarding_queue" OWNER TO "postgres";


COMMENT ON COLUMN "public"."email_forwarding_queue"."pipeline_debug" IS 'Structured ingestion diagnostics (sizes, unwrap path). Not user-facing errors.';



COMMENT ON COLUMN "public"."email_forwarding_queue"."ingestion_stage" IS 'Last pipeline milestone for debugging (e.g. bodies_resolved, completed).';



CREATE TABLE IF NOT EXISTS "public"."expense_splits" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "expense_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "owed_amount" numeric DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."expense_splits" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."fcm_tokens" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "token" "text" NOT NULL,
    "platform" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "fcm_tokens_platform_check" CHECK (("platform" = ANY (ARRAY['android'::"text", 'ios'::"text"])))
);


ALTER TABLE "public"."fcm_tokens" OWNER TO "postgres";


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


CREATE TABLE IF NOT EXISTS "public"."notifications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "type" "text" NOT NULL,
    "title" "text" NOT NULL,
    "body" "text" NOT NULL,
    "data" "jsonb" DEFAULT '{}'::"jsonb",
    "idempotency_key" "text",
    "is_read" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."notifications" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."pin_photos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "pin_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "image_url" "text" NOT NULL,
    "caption" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."pin_photos" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."pins" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "latitude" double precision NOT NULL,
    "longitude" double precision NOT NULL,
    "place_id" "text",
    "address" "text",
    "country" "text",
    "country_code" "text",
    "pin_color" "text" DEFAULT '#2563EB'::"text",
    "pin_type" "text" DEFAULT 'visited'::"text" NOT NULL,
    "visited_at" "date",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "source" "text" DEFAULT 'manual'::"text" NOT NULL,
    CONSTRAINT "pins_pin_type_check" CHECK (("pin_type" = ANY (ARRAY['visited'::"text", 'bucket_list'::"text"]))),
    CONSTRAINT "pins_source_check" CHECK (("source" = ANY (ARRAY['manual'::"text", 'photo_library'::"text"])))
);


ALTER TABLE "public"."pins" OWNER TO "postgres";


COMMENT ON COLUMN "public"."pins"."source" IS 'How the pin was created: manual or photo_library import.';



CREATE TABLE IF NOT EXISTS "public"."place_cache" (
    "place_id" "text" NOT NULL,
    "name" "text",
    "address" "text",
    "latitude" double precision,
    "longitude" double precision,
    "rating" double precision,
    "price_level" integer,
    "types" "text"[],
    "details_json" "jsonb",
    "fetched_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "ai_editorial_summary" "text",
    "ai_review_summary" "text",
    "ai_why_go" "text"[],
    "ai_know_before_you_go" "text"[],
    "ai_enriched_at" timestamp with time zone
);


ALTER TABLE "public"."place_cache" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" NOT NULL,
    "username" "text" NOT NULL,
    "display_name" "text",
    "avatar_url" "text",
    "bio" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "default_pin_color" "text" DEFAULT '#E53935'::"text",
    "preferred_airport" "text",
    "preferred_currency" "text"
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


COMMENT ON COLUMN "public"."profiles"."preferred_airport" IS 'Home or preferred airport (IATA or short label).';



COMMENT ON COLUMN "public"."profiles"."preferred_currency" IS 'Preferred ISO 4217 currency code (e.g. USD).';



CREATE TABLE IF NOT EXISTS "public"."stop_photos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "stop_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "image_url" "text" NOT NULL,
    "caption" "text",
    "sort_order" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."stop_photos" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."stops" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "trip_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "latitude" double precision NOT NULL,
    "longitude" double precision NOT NULL,
    "place_id" "text",
    "address" "text",
    "country" "text",
    "country_code" "text",
    "pin_color" "text" DEFAULT '#2563EB'::"text",
    "arrived_at" timestamp with time zone,
    "departed_at" timestamp with time zone,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."stops" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."track_points" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "trip_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "latitude" double precision NOT NULL,
    "longitude" double precision NOT NULL,
    "altitude" double precision,
    "speed" double precision,
    "accuracy" double precision,
    "recorded_at" timestamp with time zone NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."track_points" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."trip_activities" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "day_id" "uuid" NOT NULL,
    "trip_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "category" "text",
    "starts_at" timestamp with time zone,
    "duration_minutes" integer,
    "latitude" double precision,
    "longitude" double precision,
    "address" "text",
    "place_id" "text",
    "rating" double precision,
    "price_level" integer,
    "estimated_cost" numeric,
    "currency" "text",
    "booking_id" "uuid",
    "source" "text" DEFAULT 'manual'::"text" NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "travel_from_previous_minutes" integer,
    "directions_url" "text",
    "travel_mode" "text" DEFAULT 'driving'::"text" NOT NULL,
    "hero_image_url" "text",
    "hero_attribution" "text",
    "place_search_query" "text",
    "meal_anchor" boolean DEFAULT false NOT NULL,
    CONSTRAINT "trip_activities_category_check" CHECK (("category" = ANY (ARRAY['attraction'::"text", 'restaurant'::"text", 'transport'::"text", 'shopping'::"text", 'nature'::"text", 'nightlife'::"text", 'custom'::"text"]))),
    CONSTRAINT "trip_activities_source_check" CHECK (("source" = ANY (ARRAY['manual'::"text", 'ai_suggestion'::"text", 'search'::"text"]))),
    CONSTRAINT "valid_travel_mode" CHECK (("travel_mode" = ANY (ARRAY['driving'::"text", 'walking'::"text", 'transit'::"text", 'bicycling'::"text"])))
);

ALTER TABLE ONLY "public"."trip_activities" REPLICA IDENTITY FULL;


ALTER TABLE "public"."trip_activities" OWNER TO "postgres";


COMMENT ON COLUMN "public"."trip_activities"."travel_from_previous_minutes" IS 'Estimated travel time in minutes from the previous stop on the same day (nullable for first item).';



COMMENT ON COLUMN "public"."trip_activities"."directions_url" IS 'Google Maps directions URL from previous stop to this one (same day), when resolvable.';



COMMENT ON COLUMN "public"."trip_activities"."hero_image_url" IS 'Optional hero image URL for activity/place detail (e.g. Unsplash CDN).';



COMMENT ON COLUMN "public"."trip_activities"."hero_attribution" IS 'Attribution line for hero_image_url (e.g. Photo by … on Unsplash).';



COMMENT ON COLUMN "public"."trip_activities"."place_search_query" IS 'Optional text used to resolve lat/lng/place_id client-side after AI plan (no Google on plan path).';



COMMENT ON COLUMN "public"."trip_activities"."meal_anchor" IS 'When true, the route optimizer should not reorder this activity. Set by AI for meal stops that serve as geographic connectors between activity clusters.';



CREATE TABLE IF NOT EXISTS "public"."trip_activity_attachments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "activity_id" "uuid" NOT NULL,
    "trip_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "attachment_type" "text" NOT NULL,
    "storage_path" "text",
    "url" "text",
    "original_filename" "text",
    "mime_type" "text",
    "file_size_bytes" integer,
    "label" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "is_cover" boolean DEFAULT false NOT NULL,
    CONSTRAINT "trip_activity_attachments_attachment_type_check" CHECK (("attachment_type" = ANY (ARRAY['photo'::"text", 'file'::"text", 'link'::"text"]))),
    CONSTRAINT "valid_attachment" CHECK (((("attachment_type" = ANY (ARRAY['photo'::"text", 'file'::"text"])) AND ("storage_path" IS NOT NULL)) OR (("attachment_type" = 'link'::"text") AND ("url" IS NOT NULL))))
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


CREATE TABLE IF NOT EXISTS "public"."trip_booking_attachments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "booking_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "storage_path" "text" NOT NULL,
    "original_filename" "text",
    "mime_type" "text",
    "file_size_bytes" integer,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."trip_booking_attachments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."trip_bookings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "trip_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "kind" "text" NOT NULL,
    "title" "text" NOT NULL,
    "confirmation_code" "text",
    "provider" "text",
    "starts_at" timestamp with time zone,
    "ends_at" timestamp with time zone,
    "start_location" "text",
    "end_location" "text",
    "start_lat" double precision,
    "start_lng" double precision,
    "end_lat" double precision,
    "end_lng" double precision,
    "details_json" "jsonb" DEFAULT '{}'::"jsonb",
    "total_price" numeric,
    "currency" "text" DEFAULT 'USD'::"text",
    "source" "text" DEFAULT 'manual'::"text" NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "trip_bookings_kind_check" CHECK (("kind" = ANY (ARRAY['flight'::"text", 'car'::"text", 'lodging'::"text", 'restaurant'::"text", 'train'::"text", 'bus'::"text", 'ferry'::"text", 'cruise'::"text", 'concert'::"text", 'theater'::"text", 'tour'::"text"]))),
    CONSTRAINT "trip_bookings_source_check" CHECK (("source" = ANY (ARRAY['manual'::"text", 'upload'::"text", 'email'::"text"])))
);

ALTER TABLE ONLY "public"."trip_bookings" REPLICA IDENTITY FULL;


ALTER TABLE "public"."trip_bookings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."trip_budgets" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "trip_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "category" "text" NOT NULL,
    "planned_amount" numeric DEFAULT 0 NOT NULL,
    "spent_amount" numeric DEFAULT 0 NOT NULL,
    "currency" "text" DEFAULT 'USD'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "trip_budgets_category_check" CHECK (("category" = ANY (ARRAY['flight'::"text", 'lodging'::"text", 'car'::"text", 'food'::"text", 'activities'::"text", 'shopping'::"text", 'transport'::"text", 'other'::"text"])))
);


ALTER TABLE "public"."trip_budgets" OWNER TO "postgres";


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
    "role" "text" DEFAULT 'viewer'::"text" NOT NULL,
    "can_see_documents" boolean DEFAULT false NOT NULL,
    "can_see_notes" boolean DEFAULT false NOT NULL,
    "invited_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "accepted_at" timestamp with time zone,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "invite_count" integer DEFAULT 1 NOT NULL,
    "user_id" "uuid",
    "invited_email" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "trip_collaborators_role_check" CHECK (("role" = ANY (ARRAY['viewer'::"text", 'editor'::"text"]))),
    CONSTRAINT "trip_collaborators_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'accepted'::"text", 'declined'::"text"])))
);

ALTER TABLE ONLY "public"."trip_collaborators" REPLICA IDENTITY FULL;

ALTER TABLE ONLY "public"."trip_collaborators" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."trip_collaborators" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."trip_days" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "trip_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "date" "date" NOT NULL,
    "label" "text",
    "notes" "text",
    "day_number" integer DEFAULT 1 NOT NULL,
    "timezone" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
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
    "booking_id" "uuid",
    "title" "text" NOT NULL,
    "amount" numeric NOT NULL,
    "currency" "text" DEFAULT 'USD'::"text" NOT NULL,
    "category" "text" NOT NULL,
    "split_type" "text" DEFAULT 'equal'::"text" NOT NULL,
    "expense_date" "date" DEFAULT CURRENT_DATE NOT NULL,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "user_id" "uuid",
    "spent_at" "date",
    "payer_user_id" "uuid",
    CONSTRAINT "trip_expenses_amount_check" CHECK (("amount" > (0)::numeric)),
    CONSTRAINT "trip_expenses_category_check" CHECK (("category" = ANY (ARRAY['flight'::"text", 'lodging'::"text", 'car'::"text", 'food'::"text", 'activities'::"text", 'shopping'::"text", 'transport'::"text", 'other'::"text"]))),
    CONSTRAINT "trip_expenses_split_type_check" CHECK (("split_type" = ANY (ARRAY['equal'::"text", 'exact'::"text", 'percentage'::"text", 'full'::"text"])))
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
    "title" "text",
    "body" "text",
    "is_private" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."trip_notes" OWNER TO "postgres";


COMMENT ON TABLE "public"."trip_notes" IS 'Per-trip freeform notes; title + body, sorted by updated_at.';



CREATE TABLE IF NOT EXISTS "public"."trip_routes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "trip_id" "uuid" NOT NULL,
    "day_number" integer NOT NULL,
    "origin_lat" double precision NOT NULL,
    "origin_lng" double precision NOT NULL,
    "dest_lat" double precision NOT NULL,
    "dest_lng" double precision NOT NULL,
    "travel_mode" "text" DEFAULT 'driving'::"text" NOT NULL,
    "encoded_polyline" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."trip_routes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."trips" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "cover_image_url" "text",
    "start_date" "date",
    "end_date" "date",
    "is_active" boolean DEFAULT false NOT NULL,
    "privacy" "text" DEFAULT 'private'::"text" NOT NULL,
    "status" "text" DEFAULT 'planned'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "destination" "text" DEFAULT ''::"text" NOT NULL,
    "destination_place_id" "text",
    "cover_attribution" "text",
    "destinations" "jsonb",
    "display_timezone" "text",
    "total_budget" numeric DEFAULT 0,
    "budget_currency" "text" DEFAULT 'USD'::"text" NOT NULL,
    CONSTRAINT "trips_privacy_check" CHECK (("privacy" = ANY (ARRAY['private'::"text", 'public'::"text"]))),
    CONSTRAINT "trips_status_check" CHECK (("status" = ANY (ARRAY['planned'::"text", 'active'::"text", 'completed'::"text"])))
);

ALTER TABLE ONLY "public"."trips" REPLICA IDENTITY FULL;


ALTER TABLE "public"."trips" OWNER TO "postgres";


COMMENT ON COLUMN "public"."trips"."destination" IS 'Display label for primary city (from Places)';



COMMENT ON COLUMN "public"."trips"."destination_place_id" IS 'Google Place ID for the trip city';



COMMENT ON COLUMN "public"."trips"."cover_attribution" IS 'JSON or plain text for Unsplash / cover credit';



COMMENT ON COLUMN "public"."trips"."destinations" IS 'Ordered JSON array of {label, place_id, start_date, end_date} objects for multi-city trips';



COMMENT ON COLUMN "public"."trips"."display_timezone" IS 'IANA timezone id for destination-local display of activity times (e.g. Europe/Paris).';



CREATE TABLE IF NOT EXISTS "public"."usage_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "feature" "text" NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."usage_events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_forwarding_addresses" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "trip_id" "uuid" NOT NULL,
    "address_token" "text" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."user_forwarding_addresses" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_stats" (
    "user_id" "uuid" NOT NULL,
    "countries_visited" integer DEFAULT 0 NOT NULL,
    "total_trips" integer DEFAULT 0 NOT NULL,
    "total_distance_km" double precision DEFAULT 0 NOT NULL,
    "total_pins" integer DEFAULT 0 NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."user_stats" OWNER TO "postgres";


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
    ADD CONSTRAINT "email_forwarding_queue_message_id_hash_key" UNIQUE ("message_id_hash");



ALTER TABLE ONLY "public"."email_forwarding_queue"
    ADD CONSTRAINT "email_forwarding_queue_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."expense_splits"
    ADD CONSTRAINT "expense_splits_expense_id_user_id_key" UNIQUE ("expense_id", "user_id");



ALTER TABLE ONLY "public"."expense_splits"
    ADD CONSTRAINT "expense_splits_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."fcm_tokens"
    ADD CONSTRAINT "fcm_tokens_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."fcm_tokens"
    ADD CONSTRAINT "fcm_tokens_user_id_token_key" UNIQUE ("user_id", "token");



ALTER TABLE ONLY "public"."feedback"
    ADD CONSTRAINT "feedback_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_user_id_idempotency_key_key" UNIQUE ("user_id", "idempotency_key");



ALTER TABLE ONLY "public"."pin_photos"
    ADD CONSTRAINT "pin_photos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pins"
    ADD CONSTRAINT "pins_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."place_cache"
    ADD CONSTRAINT "place_cache_pkey" PRIMARY KEY ("place_id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_username_key" UNIQUE ("username");



ALTER TABLE ONLY "public"."stop_photos"
    ADD CONSTRAINT "stop_photos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."stops"
    ADD CONSTRAINT "stops_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."track_points"
    ADD CONSTRAINT "track_points_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."trip_activities"
    ADD CONSTRAINT "trip_activities_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."trip_activity_attachments"
    ADD CONSTRAINT "trip_activity_attachments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."trip_activity_log"
    ADD CONSTRAINT "trip_activity_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."trip_booking_attachments"
    ADD CONSTRAINT "trip_booking_attachments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."trip_bookings"
    ADD CONSTRAINT "trip_bookings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."trip_budgets"
    ADD CONSTRAINT "trip_budgets_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."trip_budgets"
    ADD CONSTRAINT "trip_budgets_trip_id_category_key" UNIQUE ("trip_id", "category");



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



ALTER TABLE ONLY "public"."trip_routes"
    ADD CONSTRAINT "trip_routes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."trip_routes"
    ADD CONSTRAINT "trip_routes_trip_id_day_number_origin_lat_origin_lng_dest_l_key" UNIQUE ("trip_id", "day_number", "origin_lat", "origin_lng", "dest_lat", "dest_lng", "travel_mode");



ALTER TABLE ONLY "public"."trips"
    ADD CONSTRAINT "trips_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."usage_events"
    ADD CONSTRAINT "usage_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_forwarding_addresses"
    ADD CONSTRAINT "user_forwarding_addresses_address_token_key" UNIQUE ("address_token");



ALTER TABLE ONLY "public"."user_forwarding_addresses"
    ADD CONSTRAINT "user_forwarding_addresses_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_forwarding_addresses"
    ADD CONSTRAINT "user_forwarding_addresses_user_trip_unique" UNIQUE ("user_id", "trip_id");



ALTER TABLE ONLY "public"."user_stats"
    ADD CONSTRAINT "user_stats_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."user_subscriptions"
    ADD CONSTRAINT "user_subscriptions_pkey" PRIMARY KEY ("user_id");



CREATE INDEX "checklist_items_checklist_id_idx" ON "public"."checklist_items" USING "btree" ("checklist_id");



CREATE INDEX "checklist_items_checklist_sort_idx" ON "public"."checklist_items" USING "btree" ("checklist_id", "sort_order");



CREATE INDEX "checklist_items_trip_idx" ON "public"."checklist_items" USING "btree" ("trip_id");



CREATE INDEX "email_forwarding_queue_status_idx" ON "public"."email_forwarding_queue" USING "btree" ("status");



CREATE INDEX "email_forwarding_queue_user_id_idx" ON "public"."email_forwarding_queue" USING "btree" ("user_id");



CREATE INDEX "expense_splits_expense_id_idx" ON "public"."expense_splits" USING "btree" ("expense_id");



CREATE INDEX "expense_splits_user_id_idx" ON "public"."expense_splits" USING "btree" ("user_id");



CREATE INDEX "fcm_tokens_user_id_idx" ON "public"."fcm_tokens" USING "btree" ("user_id");



CREATE INDEX "idx_activity_attachments_activity" ON "public"."trip_activity_attachments" USING "btree" ("activity_id");



CREATE INDEX "idx_activity_attachments_trip" ON "public"."trip_activity_attachments" USING "btree" ("trip_id");



CREATE INDEX "idx_city_places_query" ON "public"."city_places" USING "btree" ("city_profile_id", "status", "wayfind_category", "min_scope");



CREATE INDEX "idx_city_places_refresh" ON "public"."city_places" USING "btree" ("last_refreshed_at") WHERE ("status" = 'active'::"text");



CREATE INDEX "idx_city_profiles_geo" ON "public"."city_profiles" USING "btree" ("center_lat", "center_lng");



CREATE INDEX "idx_collaboration_push_throttle_user" ON "public"."collaboration_push_throttle" USING "btree" ("user_id");



CREATE INDEX "idx_nearby_meals_activity" ON "public"."city_place_nearby_meals" USING "btree" ("city_profile_id", "activity_place_id");



CREATE INDEX "idx_place_cache_fetched" ON "public"."place_cache" USING "btree" ("fetched_at");



CREATE INDEX "idx_travel_times_lookup" ON "public"."city_travel_times" USING "btree" ("city_profile_id", "from_place_id", "to_place_id");



CREATE INDEX "idx_trip_activity_log_trip_created" ON "public"."trip_activity_log" USING "btree" ("trip_id", "created_at" DESC);



CREATE INDEX "idx_trip_collaborators_trip_id" ON "public"."trip_collaborators" USING "btree" ("trip_id");



CREATE INDEX "idx_trip_collaborators_user_id" ON "public"."trip_collaborators" USING "btree" ("user_id");



CREATE INDEX "idx_trip_invites_token" ON "public"."trip_invites" USING "btree" ("token");



CREATE INDEX "idx_trip_invites_trip_id" ON "public"."trip_invites" USING "btree" ("trip_id");



CREATE INDEX "idx_trip_invites_trip_invited_email" ON "public"."trip_invites" USING "btree" ("trip_id", "lower"(TRIM(BOTH FROM "invited_email"))) WHERE (("invited_email" IS NOT NULL) AND ("is_active" = true));



CREATE INDEX "idx_trip_routes_trip_day" ON "public"."trip_routes" USING "btree" ("trip_id", "day_number");



CREATE INDEX "idx_usage_events_user_feature_created_at" ON "public"."usage_events" USING "btree" ("user_id", "feature", "created_at" DESC);



CREATE INDEX "idx_user_subscriptions_expires_at" ON "public"."user_subscriptions" USING "btree" ("expires_at") WHERE ("is_pro" = true);



CREATE INDEX "notifications_user_id_created_at_idx" ON "public"."notifications" USING "btree" ("user_id", "created_at" DESC);



CREATE INDEX "notifications_user_id_unread_idx" ON "public"."notifications" USING "btree" ("user_id") WHERE ("is_read" = false);



CREATE INDEX "pin_photos_pin_id_idx" ON "public"."pin_photos" USING "btree" ("pin_id");



CREATE INDEX "pins_pin_type_idx" ON "public"."pins" USING "btree" ("pin_type");



CREATE INDEX "pins_user_id_idx" ON "public"."pins" USING "btree" ("user_id");



CREATE INDEX "stop_photos_stop_id_idx" ON "public"."stop_photos" USING "btree" ("stop_id");



CREATE INDEX "stops_trip_id_idx" ON "public"."stops" USING "btree" ("trip_id");



CREATE INDEX "stops_user_id_idx" ON "public"."stops" USING "btree" ("user_id");



CREATE INDEX "track_points_recorded_at_idx" ON "public"."track_points" USING "btree" ("recorded_at");



CREATE INDEX "track_points_trip_id_idx" ON "public"."track_points" USING "btree" ("trip_id");



CREATE INDEX "trip_activities_day_id_idx" ON "public"."trip_activities" USING "btree" ("day_id");



CREATE INDEX "trip_activities_trip_id_idx" ON "public"."trip_activities" USING "btree" ("trip_id");



CREATE INDEX "trip_booking_attachments_booking_id_idx" ON "public"."trip_booking_attachments" USING "btree" ("booking_id");



CREATE INDEX "trip_bookings_trip_id_idx" ON "public"."trip_bookings" USING "btree" ("trip_id");



CREATE INDEX "trip_bookings_user_id_idx" ON "public"."trip_bookings" USING "btree" ("user_id");



CREATE INDEX "trip_budgets_trip_id_idx" ON "public"."trip_budgets" USING "btree" ("trip_id");



CREATE INDEX "trip_checklists_trip_id_idx" ON "public"."trip_checklists" USING "btree" ("trip_id");



CREATE INDEX "trip_checklists_trip_sort_idx" ON "public"."trip_checklists" USING "btree" ("trip_id", "sort_order");



CREATE UNIQUE INDEX "trip_checklists_trip_template_key_uidx" ON "public"."trip_checklists" USING "btree" ("trip_id", "template_key") WHERE ("template_key" IS NOT NULL);



CREATE INDEX "trip_collaborators_trip_id_idx" ON "public"."trip_collaborators" USING "btree" ("trip_id");



CREATE UNIQUE INDEX "trip_days_trip_id_date_idx" ON "public"."trip_days" USING "btree" ("trip_id", "date");



CREATE INDEX "trip_days_trip_id_idx" ON "public"."trip_days" USING "btree" ("trip_id");



CREATE INDEX "trip_documents_trip_created_idx" ON "public"."trip_documents" USING "btree" ("trip_id", "created_at" DESC);



CREATE INDEX "trip_documents_uploaded_by_idx" ON "public"."trip_documents" USING "btree" ("uploaded_by");



CREATE INDEX "trip_expenses_trip_created_idx" ON "public"."trip_expenses" USING "btree" ("trip_id", "created_at" DESC);



CREATE INDEX "trip_expenses_trip_id_idx" ON "public"."trip_expenses" USING "btree" ("trip_id");



CREATE INDEX "trip_expenses_trip_spent_idx" ON "public"."trip_expenses" USING "btree" ("trip_id", "spent_at" DESC NULLS LAST);



CREATE INDEX "trip_notes_trip_id_idx" ON "public"."trip_notes" USING "btree" ("trip_id");



CREATE INDEX "trip_notes_trip_updated_idx" ON "public"."trip_notes" USING "btree" ("trip_id", "updated_at" DESC);



CREATE INDEX "trips_status_idx" ON "public"."trips" USING "btree" ("status");



CREATE INDEX "trips_user_id_idx" ON "public"."trips" USING "btree" ("user_id");



CREATE INDEX "user_forwarding_addresses_token_idx" ON "public"."user_forwarding_addresses" USING "btree" ("address_token");



CREATE OR REPLACE TRIGGER "checklist_items_set_updated_at" BEFORE UPDATE ON "public"."checklist_items" FOR EACH ROW EXECUTE FUNCTION "public"."checklist_items_bump_updated_at"();



CREATE OR REPLACE TRIGGER "checklist_items_sync_trip_id_trigger" BEFORE INSERT OR UPDATE OF "checklist_id" ON "public"."checklist_items" FOR EACH ROW EXECUTE FUNCTION "public"."checklist_items_sync_trip_id"();



CREATE OR REPLACE TRIGGER "on_pins_change" AFTER INSERT OR DELETE OR UPDATE ON "public"."pins" FOR EACH ROW EXECUTE FUNCTION "public"."handle_pins_change"();



CREATE OR REPLACE TRIGGER "on_profile_created" AFTER INSERT ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."handle_new_profile"();



CREATE OR REPLACE TRIGGER "on_trips_change" AFTER INSERT OR DELETE OR UPDATE ON "public"."trips" FOR EACH ROW EXECUTE FUNCTION "public"."handle_trips_change"();



CREATE OR REPLACE TRIGGER "set_activity_attachments_updated_at" BEFORE UPDATE ON "public"."trip_activity_attachments" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at"();



CREATE OR REPLACE TRIGGER "set_checklist_items_updated_at" BEFORE UPDATE ON "public"."checklist_items" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at"();



CREATE OR REPLACE TRIGGER "set_fcm_tokens_updated_at" BEFORE UPDATE ON "public"."fcm_tokens" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at"();



CREATE OR REPLACE TRIGGER "set_profiles_updated_at" BEFORE UPDATE ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at"();



CREATE OR REPLACE TRIGGER "set_trip_activities_updated_at" BEFORE UPDATE ON "public"."trip_activities" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at"();



CREATE OR REPLACE TRIGGER "set_trip_booking_attachments_updated_at" BEFORE UPDATE ON "public"."trip_booking_attachments" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at"();



CREATE OR REPLACE TRIGGER "set_trip_bookings_updated_at" BEFORE UPDATE ON "public"."trip_bookings" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at"();



CREATE OR REPLACE TRIGGER "set_trip_budgets_updated_at" BEFORE UPDATE ON "public"."trip_budgets" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at"();



CREATE OR REPLACE TRIGGER "set_trip_checklists_updated_at" BEFORE UPDATE ON "public"."trip_checklists" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at"();



CREATE OR REPLACE TRIGGER "set_trip_days_updated_at" BEFORE UPDATE ON "public"."trip_days" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at"();



CREATE OR REPLACE TRIGGER "set_trip_expenses_updated_at" BEFORE UPDATE ON "public"."trip_expenses" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at"();



CREATE OR REPLACE TRIGGER "set_trip_notes_updated_at" BEFORE UPDATE ON "public"."trip_notes" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at"();



CREATE OR REPLACE TRIGGER "set_trips_updated_at" BEFORE UPDATE ON "public"."trips" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at"();



CREATE OR REPLACE TRIGGER "tr_trip_activity_attachments_max_photos" BEFORE INSERT ON "public"."trip_activity_attachments" FOR EACH ROW EXECUTE FUNCTION "public"."enforce_trip_activity_max_photos"();



CREATE OR REPLACE TRIGGER "trip_activities_log_collab" AFTER INSERT OR DELETE OR UPDATE ON "public"."trip_activities" FOR EACH ROW EXECUTE FUNCTION "public"."tg_log_trip_activity_changes"();



CREATE OR REPLACE TRIGGER "trip_activity_log_to_collaboration_notify" AFTER INSERT ON "public"."trip_activity_log" FOR EACH ROW EXECUTE FUNCTION "supabase_functions"."http_request"('https://zmkbdnutedbwkinjukbg.supabase.co/functions/v1/collaboration-notify', 'POST', '{"Content-type":"application/json","X-Wayfind-Collab-Secret":"ZiY66CHpUYwXV5hm1fuuHcvm+OQUgAXLPCi5DCGtO/c="}', '{}', '5000');



CREATE OR REPLACE TRIGGER "trip_bookings_log_collab" AFTER INSERT OR DELETE OR UPDATE ON "public"."trip_bookings" FOR EACH ROW EXECUTE FUNCTION "public"."tg_log_trip_booking_changes"();



CREATE OR REPLACE TRIGGER "trip_checklists_set_updated_at" BEFORE UPDATE ON "public"."trip_checklists" FOR EACH ROW EXECUTE FUNCTION "public"."trip_checklists_bump_updated_at"();



CREATE OR REPLACE TRIGGER "trip_collaborators_log_leave" AFTER DELETE ON "public"."trip_collaborators" FOR EACH ROW EXECUTE FUNCTION "public"."tg_log_trip_collaborator_leave"();



CREATE OR REPLACE TRIGGER "trip_collaborators_log_pending_decline" AFTER DELETE ON "public"."trip_collaborators" FOR EACH ROW EXECUTE FUNCTION "public"."tg_log_pending_invite_declined"();



CREATE OR REPLACE TRIGGER "trip_collaborators_log_role" AFTER UPDATE ON "public"."trip_collaborators" FOR EACH ROW EXECUTE FUNCTION "public"."tg_log_trip_collaborator_role"();



CREATE OR REPLACE TRIGGER "trip_collaborators_set_updated_at" BEFORE UPDATE ON "public"."trip_collaborators" FOR EACH ROW EXECUTE FUNCTION "public"."trip_collaborators_bump_updated_at"();



CREATE OR REPLACE TRIGGER "trip_expenses_set_updated_at" BEFORE UPDATE ON "public"."trip_expenses" FOR EACH ROW EXECUTE FUNCTION "public"."trip_expenses_bump_updated_at"();



CREATE OR REPLACE TRIGGER "trip_notes_set_updated_at" BEFORE UPDATE ON "public"."trip_notes" FOR EACH ROW EXECUTE FUNCTION "public"."trip_notes_bump_updated_at"();



CREATE OR REPLACE TRIGGER "trips_log_updated" AFTER UPDATE ON "public"."trips" FOR EACH ROW EXECUTE FUNCTION "public"."tg_log_trip_updated"();



CREATE OR REPLACE TRIGGER "trips_prevent_collaborator_rename_trg" BEFORE UPDATE ON "public"."trips" FOR EACH ROW EXECUTE FUNCTION "public"."trips_prevent_collaborator_rename"();



CREATE OR REPLACE TRIGGER "user_subscriptions_set_updated_at" BEFORE UPDATE ON "public"."user_subscriptions" FOR EACH ROW EXECUTE FUNCTION "public"."user_subscriptions_bump_updated_at"();



ALTER TABLE ONLY "public"."checklist_items"
    ADD CONSTRAINT "checklist_items_checklist_id_fkey" FOREIGN KEY ("checklist_id") REFERENCES "public"."trip_checklists"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."checklist_items"
    ADD CONSTRAINT "checklist_items_trip_id_fkey" FOREIGN KEY ("trip_id") REFERENCES "public"."trips"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."checklist_items"
    ADD CONSTRAINT "checklist_items_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."city_place_nearby_meals"
    ADD CONSTRAINT "city_place_nearby_meals_city_profile_id_fkey" FOREIGN KEY ("city_profile_id") REFERENCES "public"."city_profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."city_places"
    ADD CONSTRAINT "city_places_city_profile_id_fkey" FOREIGN KEY ("city_profile_id") REFERENCES "public"."city_profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."city_travel_times"
    ADD CONSTRAINT "city_travel_times_city_profile_id_fkey" FOREIGN KEY ("city_profile_id") REFERENCES "public"."city_profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."collaboration_push_throttle"
    ADD CONSTRAINT "collaboration_push_throttle_trip_id_fkey" FOREIGN KEY ("trip_id") REFERENCES "public"."trips"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."email_forwarding_queue"
    ADD CONSTRAINT "email_forwarding_queue_trip_id_fkey" FOREIGN KEY ("trip_id") REFERENCES "public"."trips"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."email_forwarding_queue"
    ADD CONSTRAINT "email_forwarding_queue_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."expense_splits"
    ADD CONSTRAINT "expense_splits_expense_id_fkey" FOREIGN KEY ("expense_id") REFERENCES "public"."trip_expenses"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."expense_splits"
    ADD CONSTRAINT "expense_splits_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."fcm_tokens"
    ADD CONSTRAINT "fcm_tokens_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."feedback"
    ADD CONSTRAINT "feedback_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."pin_photos"
    ADD CONSTRAINT "pin_photos_pin_id_fkey" FOREIGN KEY ("pin_id") REFERENCES "public"."pins"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."pin_photos"
    ADD CONSTRAINT "pin_photos_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."pins"
    ADD CONSTRAINT "pins_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."stop_photos"
    ADD CONSTRAINT "stop_photos_stop_id_fkey" FOREIGN KEY ("stop_id") REFERENCES "public"."stops"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."stop_photos"
    ADD CONSTRAINT "stop_photos_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."stops"
    ADD CONSTRAINT "stops_trip_id_fkey" FOREIGN KEY ("trip_id") REFERENCES "public"."trips"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."stops"
    ADD CONSTRAINT "stops_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."track_points"
    ADD CONSTRAINT "track_points_trip_id_fkey" FOREIGN KEY ("trip_id") REFERENCES "public"."trips"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."track_points"
    ADD CONSTRAINT "track_points_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_activities"
    ADD CONSTRAINT "trip_activities_booking_id_fkey" FOREIGN KEY ("booking_id") REFERENCES "public"."trip_bookings"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."trip_activities"
    ADD CONSTRAINT "trip_activities_day_id_fkey" FOREIGN KEY ("day_id") REFERENCES "public"."trip_days"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_activities"
    ADD CONSTRAINT "trip_activities_trip_id_fkey" FOREIGN KEY ("trip_id") REFERENCES "public"."trips"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_activities"
    ADD CONSTRAINT "trip_activities_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_activity_attachments"
    ADD CONSTRAINT "trip_activity_attachments_activity_id_fkey" FOREIGN KEY ("activity_id") REFERENCES "public"."trip_activities"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_activity_attachments"
    ADD CONSTRAINT "trip_activity_attachments_trip_id_fkey" FOREIGN KEY ("trip_id") REFERENCES "public"."trips"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_activity_attachments"
    ADD CONSTRAINT "trip_activity_attachments_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_activity_log"
    ADD CONSTRAINT "trip_activity_log_trip_id_fkey" FOREIGN KEY ("trip_id") REFERENCES "public"."trips"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_activity_log"
    ADD CONSTRAINT "trip_activity_log_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."trip_booking_attachments"
    ADD CONSTRAINT "trip_booking_attachments_booking_id_fkey" FOREIGN KEY ("booking_id") REFERENCES "public"."trip_bookings"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_booking_attachments"
    ADD CONSTRAINT "trip_booking_attachments_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_bookings"
    ADD CONSTRAINT "trip_bookings_trip_id_fkey" FOREIGN KEY ("trip_id") REFERENCES "public"."trips"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_bookings"
    ADD CONSTRAINT "trip_bookings_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_budgets"
    ADD CONSTRAINT "trip_budgets_trip_id_fkey" FOREIGN KEY ("trip_id") REFERENCES "public"."trips"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_budgets"
    ADD CONSTRAINT "trip_budgets_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_checklists"
    ADD CONSTRAINT "trip_checklists_trip_id_fkey" FOREIGN KEY ("trip_id") REFERENCES "public"."trips"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_checklists"
    ADD CONSTRAINT "trip_checklists_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_collaborators"
    ADD CONSTRAINT "trip_collaborators_trip_id_fkey" FOREIGN KEY ("trip_id") REFERENCES "public"."trips"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_collaborators"
    ADD CONSTRAINT "trip_collaborators_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_days"
    ADD CONSTRAINT "trip_days_trip_id_fkey" FOREIGN KEY ("trip_id") REFERENCES "public"."trips"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_days"
    ADD CONSTRAINT "trip_days_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_documents"
    ADD CONSTRAINT "trip_documents_trip_id_fkey" FOREIGN KEY ("trip_id") REFERENCES "public"."trips"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_documents"
    ADD CONSTRAINT "trip_documents_uploaded_by_fkey" FOREIGN KEY ("uploaded_by") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_expenses"
    ADD CONSTRAINT "trip_expenses_booking_id_fkey" FOREIGN KEY ("booking_id") REFERENCES "public"."trip_bookings"("id") ON DELETE SET NULL;



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
    ADD CONSTRAINT "trip_notes_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_routes"
    ADD CONSTRAINT "trip_routes_trip_id_fkey" FOREIGN KEY ("trip_id") REFERENCES "public"."trips"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trips"
    ADD CONSTRAINT "trips_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."usage_events"
    ADD CONSTRAINT "usage_events_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_forwarding_addresses"
    ADD CONSTRAINT "user_forwarding_addresses_trip_id_fkey" FOREIGN KEY ("trip_id") REFERENCES "public"."trips"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_forwarding_addresses"
    ADD CONSTRAINT "user_forwarding_addresses_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_stats"
    ADD CONSTRAINT "user_stats_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_subscriptions"
    ADD CONSTRAINT "user_subscriptions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



CREATE POLICY "Collaborators can view bookings" ON "public"."trip_bookings" FOR SELECT USING ("public"."is_trip_member"("trip_id", "auth"."uid"()));



CREATE POLICY "Editors can delete activities" ON "public"."trip_activities" FOR DELETE USING ("public"."is_trip_editor"("trip_id", "auth"."uid"()));



CREATE POLICY "Editors can delete checklist items" ON "public"."checklist_items" FOR DELETE USING ((EXISTS ( SELECT 1
   FROM "public"."trip_checklists" "tc"
  WHERE (("tc"."id" = "checklist_items"."checklist_id") AND "public"."is_trip_editor"("tc"."trip_id", "auth"."uid"())))));



CREATE POLICY "Editors can delete checklists" ON "public"."trip_checklists" FOR DELETE USING ("public"."is_trip_editor"("trip_id", "auth"."uid"()));



CREATE POLICY "Editors can manage activities" ON "public"."trip_activities" FOR INSERT WITH CHECK ("public"."is_trip_editor"("trip_id", "auth"."uid"()));



CREATE POLICY "Editors can manage checklist items" ON "public"."checklist_items" FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."trip_checklists" "tc"
  WHERE (("tc"."id" = "checklist_items"."checklist_id") AND "public"."is_trip_editor"("tc"."trip_id", "auth"."uid"())))));



CREATE POLICY "Editors can manage checklists" ON "public"."trip_checklists" FOR INSERT WITH CHECK ("public"."is_trip_editor"("trip_id", "auth"."uid"()));



CREATE POLICY "Editors can manage days" ON "public"."trip_days" FOR INSERT WITH CHECK ("public"."is_trip_editor"("trip_id", "auth"."uid"()));



CREATE POLICY "Editors can update activities" ON "public"."trip_activities" FOR UPDATE USING ("public"."is_trip_editor"("trip_id", "auth"."uid"()));



CREATE POLICY "Editors can update checklist items" ON "public"."checklist_items" FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM "public"."trip_checklists" "tc"
  WHERE (("tc"."id" = "checklist_items"."checklist_id") AND "public"."is_trip_editor"("tc"."trip_id", "auth"."uid"())))));



CREATE POLICY "Editors can update checklists" ON "public"."trip_checklists" FOR UPDATE USING ("public"."is_trip_editor"("trip_id", "auth"."uid"()));



CREATE POLICY "Editors can update days" ON "public"."trip_days" FOR UPDATE USING ("public"."is_trip_editor"("trip_id", "auth"."uid"()));



CREATE POLICY "Editors can update shared trips" ON "public"."trips" FOR UPDATE USING ("public"."is_trip_editor"("id", "auth"."uid"())) WITH CHECK ("public"."is_trip_editor"("id", "auth"."uid"()));



CREATE POLICY "Editors can update spent amounts" ON "public"."trip_budgets" FOR UPDATE USING ("public"."is_trip_editor"("trip_id", "auth"."uid"()));



CREATE POLICY "Expense creator can delete splits" ON "public"."expense_splits" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."trip_expenses" "e"
  WHERE (("e"."id" = "expense_splits"."expense_id") AND ("e"."payer_user_id" = ( SELECT "auth"."uid"() AS "uid"))))));



CREATE POLICY "Expense creator can update splits" ON "public"."expense_splits" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."trip_expenses" "e"
  WHERE (("e"."id" = "expense_splits"."expense_id") AND ("e"."payer_user_id" = ( SELECT "auth"."uid"() AS "uid"))))));



CREATE POLICY "Members can insert expenses" ON "public"."trip_expenses" FOR INSERT WITH CHECK ("public"."is_trip_member"("trip_id", "auth"."uid"()));



CREATE POLICY "Members can insert splits" ON "public"."expense_splits" FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."trip_expenses" "te"
  WHERE (("te"."id" = "expense_splits"."expense_id") AND "public"."is_trip_member"("te"."trip_id", "auth"."uid"())))));



CREATE POLICY "Members can view activities" ON "public"."trip_activities" FOR SELECT USING ("public"."is_trip_member"("trip_id", "auth"."uid"()));



CREATE POLICY "Members can view budgets" ON "public"."trip_budgets" FOR SELECT USING ("public"."is_trip_member"("trip_id", "auth"."uid"()));



CREATE POLICY "Members can view checklist items" ON "public"."checklist_items" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."trip_checklists" "tc"
  WHERE (("tc"."id" = "checklist_items"."checklist_id") AND "public"."is_trip_member"("tc"."trip_id", "auth"."uid"())))));



CREATE POLICY "Members can view checklists" ON "public"."trip_checklists" FOR SELECT USING ("public"."is_trip_member"("trip_id", "auth"."uid"()));



CREATE POLICY "Members can view days" ON "public"."trip_days" FOR SELECT USING ("public"."is_trip_member"("trip_id", "auth"."uid"()));



CREATE POLICY "Members can view expenses" ON "public"."trip_expenses" FOR SELECT USING ("public"."is_trip_member"("trip_id", "auth"."uid"()));



CREATE POLICY "Members can view splits" ON "public"."expense_splits" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."trip_expenses" "te"
  WHERE (("te"."id" = "expense_splits"."expense_id") AND "public"."is_trip_member"("te"."trip_id", "auth"."uid"())))));



CREATE POLICY "Owner full access to activities" ON "public"."trip_activities" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Owner full access to activity attachments" ON "public"."trip_activity_attachments" TO "authenticated" USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "Owner full access to budgets" ON "public"."trip_budgets" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Owner full access to checklist items" ON "public"."checklist_items" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Owner full access to checklists" ON "public"."trip_checklists" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Owner full access to days" ON "public"."trip_days" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Owner full access to notes" ON "public"."trip_notes" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Public profiles are viewable by everyone" ON "public"."profiles" FOR SELECT USING (true);



CREATE POLICY "Public trips are viewable by everyone" ON "public"."trips" FOR SELECT USING (("privacy" = 'public'::"text"));



CREATE POLICY "Service role can insert notifications" ON "public"."notifications" FOR INSERT WITH CHECK (true);



CREATE POLICY "Service role full access on place_cache" ON "public"."place_cache" USING (true) WITH CHECK (true);



CREATE POLICY "Stats are updatable by owner only" ON "public"."user_stats" FOR UPDATE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Stop photos of public trips are viewable" ON "public"."stop_photos" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM ("public"."stops" "s"
     JOIN "public"."trips" "t" ON (("t"."id" = "s"."trip_id")))
  WHERE (("s"."id" = "stop_photos"."stop_id") AND ("t"."privacy" = 'public'::"text")))));



CREATE POLICY "Stops of public trips are viewable by everyone" ON "public"."stops" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."trips" "t"
  WHERE (("t"."id" = "stops"."trip_id") AND ("t"."privacy" = 'public'::"text")))));



CREATE POLICY "Trip owner can delete booking attachments" ON "public"."trip_booking_attachments" FOR DELETE USING ((EXISTS ( SELECT 1
   FROM "public"."trip_bookings" "tb"
  WHERE (("tb"."id" = "trip_booking_attachments"."booking_id") AND "public"."is_trip_owner"("tb"."trip_id", "auth"."uid"())))));



CREATE POLICY "Trip owner can delete bookings" ON "public"."trip_bookings" FOR DELETE USING ("public"."is_trip_owner"("trip_id", "auth"."uid"()));



CREATE POLICY "Trip owner can insert booking attachments" ON "public"."trip_booking_attachments" FOR INSERT WITH CHECK ((("auth"."uid"() = "user_id") AND (EXISTS ( SELECT 1
   FROM "public"."trip_bookings" "tb"
  WHERE (("tb"."id" = "trip_booking_attachments"."booking_id") AND "public"."is_trip_owner"("tb"."trip_id", "auth"."uid"()))))));



CREATE POLICY "Trip owner can insert bookings" ON "public"."trip_bookings" FOR INSERT WITH CHECK ("public"."is_trip_owner"("trip_id", "auth"."uid"()));



CREATE POLICY "Trip owner can update booking attachments" ON "public"."trip_booking_attachments" FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM "public"."trip_bookings" "tb"
  WHERE (("tb"."id" = "trip_booking_attachments"."booking_id") AND "public"."is_trip_owner"("tb"."trip_id", "auth"."uid"())))));



CREATE POLICY "Trip owner can update bookings" ON "public"."trip_bookings" FOR UPDATE USING ("public"."is_trip_owner"("trip_id", "auth"."uid"()));



CREATE POLICY "Users can create pins" ON "public"."pins" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can create stops for their own trips" ON "public"."stops" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can create trips" ON "public"."trips" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can delete their own pin photos" ON "public"."pin_photos" FOR DELETE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can delete their own pins" ON "public"."pins" FOR DELETE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can delete their own profile" ON "public"."profiles" FOR DELETE USING (("auth"."uid"() = "id"));



CREATE POLICY "Users can delete their own stop photos" ON "public"."stop_photos" FOR DELETE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can delete their own stops" ON "public"."stops" FOR DELETE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can delete their own track points" ON "public"."track_points" FOR DELETE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can delete their own trips" ON "public"."trips" FOR DELETE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can insert their own pin photos" ON "public"."pin_photos" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can insert their own profile" ON "public"."profiles" FOR INSERT WITH CHECK (("auth"."uid"() = "id"));



CREATE POLICY "Users can insert their own stop photos" ON "public"."stop_photos" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can insert their own track points" ON "public"."track_points" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can mark own notifications as read" ON "public"."notifications" FOR UPDATE USING (("auth"."uid"() = "user_id")) WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can read own notifications" ON "public"."notifications" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can submit feedback" ON "public"."feedback" FOR INSERT TO "authenticated" WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can update their own pins" ON "public"."pins" FOR UPDATE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can update their own profile" ON "public"."profiles" FOR UPDATE USING (("auth"."uid"() = "id"));



CREATE POLICY "Users can update their own stops" ON "public"."stops" FOR UPDATE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can update their own trips" ON "public"."trips" FOR UPDATE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can view own feedback" ON "public"."feedback" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can view stops of their own trips" ON "public"."stops" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can view their own pin photos" ON "public"."pin_photos" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can view their own pins" ON "public"."pins" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can view their own stats" ON "public"."user_stats" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can view their own stop photos" ON "public"."stop_photos" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can view their own track points" ON "public"."track_points" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can view their own trips" ON "public"."trips" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users manage own FCM tokens" ON "public"."fcm_tokens" USING (("auth"."uid"() = "user_id")) WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users manage own forwarding addresses" ON "public"."user_forwarding_addresses" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users see own forwarded emails" ON "public"."email_forwarding_queue" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users see own forwarding addresses" ON "public"."user_forwarding_addresses" FOR SELECT USING (("auth"."uid"() = "user_id"));



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


ALTER TABLE "public"."email_forwarding_queue" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."expense_splits" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."fcm_tokens" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."feedback" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "nearby_meals_public_read" ON "public"."city_place_nearby_meals" FOR SELECT USING (true);



ALTER TABLE "public"."notifications" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."pin_photos" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."pins" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."place_cache" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."stop_photos" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."stops" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."track_points" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "travel_times_public_read" ON "public"."city_travel_times" FOR SELECT USING (true);



ALTER TABLE "public"."trip_activities" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "trip_activities_delete_collaborator" ON "public"."trip_activities" FOR DELETE TO "authenticated" USING ("public"."can_edit_trip"("trip_id"));



CREATE POLICY "trip_activities_insert_collaborator" ON "public"."trip_activities" FOR INSERT TO "authenticated" WITH CHECK ("public"."can_edit_trip"("trip_id"));



CREATE POLICY "trip_activities_select_collaborator" ON "public"."trip_activities" FOR SELECT TO "authenticated" USING ("public"."can_view_trip"("trip_id"));



CREATE POLICY "trip_activities_update_collaborator" ON "public"."trip_activities" FOR UPDATE TO "authenticated" USING ("public"."can_edit_trip"("trip_id")) WITH CHECK ("public"."can_edit_trip"("trip_id"));



ALTER TABLE "public"."trip_activity_attachments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."trip_activity_log" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "trip_activity_log_select" ON "public"."trip_activity_log" FOR SELECT TO "authenticated" USING ("public"."can_view_trip"("trip_id"));



ALTER TABLE "public"."trip_booking_attachments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."trip_bookings" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "trip_bookings_delete_collaborator" ON "public"."trip_bookings" FOR DELETE TO "authenticated" USING ("public"."can_edit_trip"("trip_id"));



CREATE POLICY "trip_bookings_insert_collaborator" ON "public"."trip_bookings" FOR INSERT TO "authenticated" WITH CHECK ("public"."can_edit_trip"("trip_id"));



CREATE POLICY "trip_bookings_select_collaborator" ON "public"."trip_bookings" FOR SELECT TO "authenticated" USING ("public"."can_view_trip"("trip_id"));



CREATE POLICY "trip_bookings_update_collaborator" ON "public"."trip_bookings" FOR UPDATE TO "authenticated" USING ("public"."can_edit_trip"("trip_id")) WITH CHECK ("public"."can_edit_trip"("trip_id"));



ALTER TABLE "public"."trip_budgets" ENABLE ROW LEVEL SECURITY;


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



ALTER TABLE "public"."trip_days" ENABLE ROW LEVEL SECURITY;


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



ALTER TABLE "public"."trip_routes" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "trip_routes_delete" ON "public"."trip_routes" FOR DELETE USING ("public"."is_trip_editor"("trip_id", "auth"."uid"()));



CREATE POLICY "trip_routes_insert" ON "public"."trip_routes" FOR INSERT WITH CHECK ("public"."is_trip_editor"("trip_id", "auth"."uid"()));



CREATE POLICY "trip_routes_select" ON "public"."trip_routes" FOR SELECT USING ("public"."is_trip_member"("trip_id", "auth"."uid"()));



CREATE POLICY "trip_routes_update" ON "public"."trip_routes" FOR UPDATE USING ("public"."is_trip_editor"("trip_id", "auth"."uid"()));



ALTER TABLE "public"."trips" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "trips_select_collaborator" ON "public"."trips" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."trip_collaborators" "tc"
  WHERE (("tc"."trip_id" = "trips"."id") AND ("tc"."user_id" = ( SELECT "auth"."uid"() AS "uid")) AND ("tc"."status" = 'accepted'::"text")))));



CREATE POLICY "trips_update_can_edit" ON "public"."trips" FOR UPDATE TO "authenticated" USING ("public"."can_edit_trip"("id")) WITH CHECK ("public"."can_edit_trip"("id"));



ALTER TABLE "public"."usage_events" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "usage_events_insert_own" ON "public"."usage_events" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "usage_events_select_own" ON "public"."usage_events" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));



ALTER TABLE "public"."user_forwarding_addresses" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_stats" ENABLE ROW LEVEL SECURITY;


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



GRANT ALL ON FUNCTION "public"."current_user_is_trip_editor"("p_trip_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."current_user_is_trip_editor"("p_trip_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."current_user_is_trip_editor"("p_trip_id" "uuid") TO "service_role";



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



GRANT ALL ON FUNCTION "public"."handle_new_profile"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_profile"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_profile"() TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_pins_change"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_pins_change"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_pins_change"() TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_trips_change"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_trips_change"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_trips_change"() TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_updated_at"() TO "service_role";



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



GRANT ALL ON FUNCTION "public"."is_trip_owner"("p_trip_id" "uuid", "p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_trip_owner"("p_trip_id" "uuid", "p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_trip_owner"("p_trip_id" "uuid", "p_user_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."list_trip_collaborator_profile_snippets"("p_trip_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."list_trip_collaborator_profile_snippets"("p_trip_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."list_trip_collaborator_profile_snippets"("p_trip_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."list_trip_collaborator_profile_snippets"("p_trip_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."lookup_auth_user_id_by_email"("p_email" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."lookup_auth_user_id_by_email"("p_email" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."lookup_auth_user_id_by_email"("p_email" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."lookup_auth_user_id_by_email"("p_email" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."notify_todays_bookings"() TO "anon";
GRANT ALL ON FUNCTION "public"."notify_todays_bookings"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."notify_todays_bookings"() TO "service_role";



GRANT ALL ON FUNCTION "public"."notify_upcoming_trips"() TO "anon";
GRANT ALL ON FUNCTION "public"."notify_upcoming_trips"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."notify_upcoming_trips"() TO "service_role";



GRANT ALL ON FUNCTION "public"."recalculate_user_stats"("uid" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."recalculate_user_stats"("uid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."recalculate_user_stats"("uid" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."send_push_notification"("p_user_id" "uuid", "p_type" "text", "p_title" "text", "p_body" "text", "p_data" "jsonb", "p_idempotency" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."send_push_notification"("p_user_id" "uuid", "p_type" "text", "p_title" "text", "p_body" "text", "p_data" "jsonb", "p_idempotency" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."send_push_notification"("p_user_id" "uuid", "p_type" "text", "p_title" "text", "p_body" "text", "p_data" "jsonb", "p_idempotency" "text") TO "service_role";



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



GRANT ALL ON FUNCTION "public"."trips_prevent_collaborator_rename"() TO "anon";
GRANT ALL ON FUNCTION "public"."trips_prevent_collaborator_rename"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trips_prevent_collaborator_rename"() TO "service_role";



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



GRANT ALL ON TABLE "public"."expense_splits" TO "anon";
GRANT ALL ON TABLE "public"."expense_splits" TO "authenticated";
GRANT ALL ON TABLE "public"."expense_splits" TO "service_role";



GRANT ALL ON TABLE "public"."fcm_tokens" TO "anon";
GRANT ALL ON TABLE "public"."fcm_tokens" TO "authenticated";
GRANT ALL ON TABLE "public"."fcm_tokens" TO "service_role";



GRANT ALL ON TABLE "public"."feedback" TO "anon";
GRANT ALL ON TABLE "public"."feedback" TO "authenticated";
GRANT ALL ON TABLE "public"."feedback" TO "service_role";



GRANT ALL ON TABLE "public"."notifications" TO "anon";
GRANT ALL ON TABLE "public"."notifications" TO "authenticated";
GRANT ALL ON TABLE "public"."notifications" TO "service_role";



GRANT ALL ON TABLE "public"."pin_photos" TO "anon";
GRANT ALL ON TABLE "public"."pin_photos" TO "authenticated";
GRANT ALL ON TABLE "public"."pin_photos" TO "service_role";



GRANT ALL ON TABLE "public"."pins" TO "anon";
GRANT ALL ON TABLE "public"."pins" TO "authenticated";
GRANT ALL ON TABLE "public"."pins" TO "service_role";



GRANT ALL ON TABLE "public"."place_cache" TO "anon";
GRANT ALL ON TABLE "public"."place_cache" TO "authenticated";
GRANT ALL ON TABLE "public"."place_cache" TO "service_role";



GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT ALL ON TABLE "public"."stop_photos" TO "anon";
GRANT ALL ON TABLE "public"."stop_photos" TO "authenticated";
GRANT ALL ON TABLE "public"."stop_photos" TO "service_role";



GRANT ALL ON TABLE "public"."stops" TO "anon";
GRANT ALL ON TABLE "public"."stops" TO "authenticated";
GRANT ALL ON TABLE "public"."stops" TO "service_role";



GRANT ALL ON TABLE "public"."track_points" TO "anon";
GRANT ALL ON TABLE "public"."track_points" TO "authenticated";
GRANT ALL ON TABLE "public"."track_points" TO "service_role";



GRANT ALL ON TABLE "public"."trip_activities" TO "anon";
GRANT ALL ON TABLE "public"."trip_activities" TO "authenticated";
GRANT ALL ON TABLE "public"."trip_activities" TO "service_role";



GRANT ALL ON TABLE "public"."trip_activity_attachments" TO "anon";
GRANT ALL ON TABLE "public"."trip_activity_attachments" TO "authenticated";
GRANT ALL ON TABLE "public"."trip_activity_attachments" TO "service_role";



GRANT ALL ON TABLE "public"."trip_activity_log" TO "anon";
GRANT ALL ON TABLE "public"."trip_activity_log" TO "authenticated";
GRANT ALL ON TABLE "public"."trip_activity_log" TO "service_role";



GRANT ALL ON TABLE "public"."trip_booking_attachments" TO "anon";
GRANT ALL ON TABLE "public"."trip_booking_attachments" TO "authenticated";
GRANT ALL ON TABLE "public"."trip_booking_attachments" TO "service_role";



GRANT ALL ON TABLE "public"."trip_bookings" TO "anon";
GRANT ALL ON TABLE "public"."trip_bookings" TO "authenticated";
GRANT ALL ON TABLE "public"."trip_bookings" TO "service_role";



GRANT ALL ON TABLE "public"."trip_budgets" TO "anon";
GRANT ALL ON TABLE "public"."trip_budgets" TO "authenticated";
GRANT ALL ON TABLE "public"."trip_budgets" TO "service_role";



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



GRANT ALL ON TABLE "public"."trip_routes" TO "anon";
GRANT ALL ON TABLE "public"."trip_routes" TO "authenticated";
GRANT ALL ON TABLE "public"."trip_routes" TO "service_role";



GRANT ALL ON TABLE "public"."trips" TO "anon";
GRANT ALL ON TABLE "public"."trips" TO "authenticated";
GRANT ALL ON TABLE "public"."trips" TO "service_role";



GRANT ALL ON TABLE "public"."usage_events" TO "anon";
GRANT ALL ON TABLE "public"."usage_events" TO "authenticated";
GRANT ALL ON TABLE "public"."usage_events" TO "service_role";



GRANT ALL ON TABLE "public"."user_forwarding_addresses" TO "anon";
GRANT ALL ON TABLE "public"."user_forwarding_addresses" TO "authenticated";
GRANT ALL ON TABLE "public"."user_forwarding_addresses" TO "service_role";



GRANT ALL ON TABLE "public"."user_stats" TO "anon";
GRANT ALL ON TABLE "public"."user_stats" TO "authenticated";
GRANT ALL ON TABLE "public"."user_stats" TO "service_role";



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







