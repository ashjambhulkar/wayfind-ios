-- Stage 11: trustworthy activity feed — booking + trip + collaborator triggers; Realtime for trip_activity_log.
-- (trip_activities logging + accept_invite join logs already exist in Stage 1 / Stage 7.)

-- ─── Bookings ─────────────────────────────────────────────────────────────
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

DROP TRIGGER IF EXISTS trip_bookings_log_collab ON public.trip_bookings;
CREATE TRIGGER trip_bookings_log_collab
  AFTER INSERT OR UPDATE OR DELETE ON public.trip_bookings
  FOR EACH ROW
  EXECUTE PROCEDURE public.tg_log_trip_booking_changes();

-- ─── Collaborator leave (accepted row removed) ─────────────────────────────
CREATE OR REPLACE FUNCTION public.tg_log_trip_collaborator_leave()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $log$
BEGIN
  IF OLD.status = 'accepted' THEN
    INSERT INTO public.trip_activity_log (trip_id, user_id, action, entity_type, entity_id, metadata)
    VALUES (
      OLD.trip_id,
      OLD.user_id,
      'collaborator_left',
      'collaborator',
      OLD.user_id,
      jsonb_build_object('role', OLD.role)
    );
  END IF;
  RETURN OLD;
END;
$log$;

DROP TRIGGER IF EXISTS trip_collaborators_log_leave ON public.trip_collaborators;
CREATE TRIGGER trip_collaborators_log_leave
  AFTER DELETE ON public.trip_collaborators
  FOR EACH ROW
  EXECUTE PROCEDURE public.tg_log_trip_collaborator_leave();

-- ─── Collaborator role change (actor = who performed the update) ─────────────
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

DROP TRIGGER IF EXISTS trip_collaborators_log_role ON public.trip_collaborators;
CREATE TRIGGER trip_collaborators_log_role
  AFTER UPDATE ON public.trip_collaborators
  FOR EACH ROW
  EXECUTE PROCEDURE public.tg_log_trip_collaborator_role();

-- ─── Trip metadata updates ───────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.tg_log_trip_updated()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $log$
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
$log$;

DROP TRIGGER IF EXISTS trips_log_updated ON public.trips;
CREATE TRIGGER trips_log_updated
  AFTER UPDATE ON public.trips
  FOR EACH ROW
  EXECUTE PROCEDURE public.tg_log_trip_updated();

-- ─── Realtime: new log rows (INSERT) for live feed ──────────────────────────
DO $realtime$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'trip_activity_log'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.trip_activity_log;
  END IF;
END
$realtime$;
