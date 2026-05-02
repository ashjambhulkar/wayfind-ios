-- Trip delete CASCADE can remove `trips` before AFTER DELETE triggers on children
-- (e.g. trip_bookings) run their INSERT into `trip_activity_log`, causing:
--   insert or update on table "trip_activity_log" violates foreign key constraint "trip_activity_log_trip_id_fkey"
-- Skip activity-log inserts when the parent trip row is already gone (bulk delete / cascade).

-- ─── trip_activities (Stage 1) ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.tg_log_trip_activity_changes()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $log$
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
$log$;

-- ─── trip_bookings (Stage 11) ────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.tg_log_trip_booking_changes()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $log$
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
$log$;

-- ─── trip_collaborators leave (Stage 12) ─────────────────────────────────────
CREATE OR REPLACE FUNCTION public.tg_log_trip_collaborator_leave()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $log$
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
$log$;

-- ─── trip_collaborators role (Stage 11) ──────────────────────────────────────
CREATE OR REPLACE FUNCTION public.tg_log_trip_collaborator_role()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $log$
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
$log$;

-- ─── Pending invite declined (Stage 13) ─────────────────────────────────────
CREATE OR REPLACE FUNCTION public.tg_log_pending_invite_declined()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $log$
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
$log$;
