-- V2c Stage 1: trip_invites, accept_invite, trip_activity_log, trip_collaborators (if missing),
-- helper functions, RLS for collaborators, Realtime for trip_activities + trip_days.
--
-- If `trip_collaborators` already exists remotely with a different shape, align columns manually
-- before applying; this migration uses IF NOT EXISTS for the table only.

-- ─── 1. trip_collaborators (owner lives on trips.user_id; rows are editor | viewer + pending) ─
CREATE TABLE IF NOT EXISTS public.trip_collaborators (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  trip_id uuid NOT NULL REFERENCES public.trips (id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  role text NOT NULL CHECK (role IN ('editor', 'viewer')),
  invited_email text,
  status text NOT NULL DEFAULT 'accepted' CHECK (status IN ('pending', 'accepted', 'declined')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- If `trip_collaborators` already existed, CREATE TABLE was skipped — add missing columns before indexes/policies.
ALTER TABLE public.trip_collaborators
  ADD COLUMN IF NOT EXISTS trip_id uuid REFERENCES public.trips (id) ON DELETE CASCADE,
  ADD COLUMN IF NOT EXISTS user_id uuid REFERENCES auth.users (id) ON DELETE CASCADE,
  ADD COLUMN IF NOT EXISTS role text,
  ADD COLUMN IF NOT EXISTS invited_email text,
  ADD COLUMN IF NOT EXISTS status text DEFAULT 'accepted',
  ADD COLUMN IF NOT EXISTS created_at timestamptz DEFAULT now(),
  ADD COLUMN IF NOT EXISTS updated_at timestamptz DEFAULT now();

-- Audit trigger reads NEW.user_id; older DBs may lack this column on child tables.
ALTER TABLE public.trip_activities
  ADD COLUMN IF NOT EXISTS user_id uuid REFERENCES auth.users (id) ON DELETE SET NULL;

UPDATE public.trip_activities a
SET user_id = t.user_id
FROM public.trips t
WHERE a.trip_id = t.id
  AND a.user_id IS NULL
  AND t.user_id IS NOT NULL;

ALTER TABLE public.trip_days
  ADD COLUMN IF NOT EXISTS user_id uuid REFERENCES auth.users (id) ON DELETE CASCADE;

UPDATE public.trip_days d
SET user_id = t.user_id
FROM public.trips t
WHERE d.trip_id = t.id
  AND d.user_id IS NULL
  AND t.user_id IS NOT NULL;

ALTER TABLE public.trip_bookings
  ADD COLUMN IF NOT EXISTS user_id uuid REFERENCES auth.users (id) ON DELETE SET NULL;

UPDATE public.trip_bookings b
SET user_id = t.user_id
FROM public.trips t
WHERE b.trip_id = t.id
  AND b.user_id IS NULL
  AND t.user_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_trip_collaborators_trip_id ON public.trip_collaborators (trip_id);
CREATE INDEX IF NOT EXISTS idx_trip_collaborators_user_id ON public.trip_collaborators (user_id);

DO $uq$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'trip_collaborators_trip_id_user_id_key'
  ) THEN
    ALTER TABLE public.trip_collaborators
      ADD CONSTRAINT trip_collaborators_trip_id_user_id_key UNIQUE (trip_id, user_id);
  END IF;
END
$uq$;

DROP TRIGGER IF EXISTS trip_collaborators_set_updated_at ON public.trip_collaborators;
CREATE OR REPLACE FUNCTION public.trip_collaborators_bump_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END
$fn$;

CREATE TRIGGER trip_collaborators_set_updated_at
  BEFORE UPDATE ON public.trip_collaborators
  FOR EACH ROW
  EXECUTE PROCEDURE public.trip_collaborators_bump_updated_at();

-- ─── 2. trip_invites ─────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.trip_invites (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  trip_id uuid NOT NULL REFERENCES public.trips (id) ON DELETE CASCADE,
  created_by uuid NOT NULL REFERENCES auth.users (id),
  token text NOT NULL,
  role text NOT NULL CHECK (role IN ('editor', 'viewer')),
  max_uses integer,
  uses integer NOT NULL DEFAULT 0,
  expires_at timestamptz DEFAULT (now() + interval '7 days'),
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT trip_invites_token_unique UNIQUE (token)
);

CREATE INDEX IF NOT EXISTS idx_trip_invites_token ON public.trip_invites (token);
CREATE INDEX IF NOT EXISTS idx_trip_invites_trip_id ON public.trip_invites (trip_id);

-- ─── 3. trip_activity_log ─────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.trip_activity_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  trip_id uuid NOT NULL REFERENCES public.trips (id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users (id),
  action text NOT NULL CHECK (
    action IN (
      'activity_added',
      'activity_updated',
      'activity_deleted',
      'booking_added',
      'booking_updated',
      'booking_deleted',
      'note_added',
      'note_updated',
      'checklist_added',
      'checklist_item_toggled',
      'day_reordered',
      'collaborator_joined',
      'collaborator_left',
      'collaborator_role_changed',
      'trip_updated'
    )
  ),
  entity_type text,
  entity_id uuid,
  entity_name text,
  metadata jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_trip_activity_log_trip_created
  ON public.trip_activity_log (trip_id, created_at DESC);

-- ─── 4. RLS helper functions (SECURITY INVOKER: auth.uid() is caller) ───────────────────
CREATE OR REPLACE FUNCTION public.can_view_trip(p_trip_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
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
  );
$$;

CREATE OR REPLACE FUNCTION public.can_edit_trip(p_trip_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
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

CREATE OR REPLACE FUNCTION public.is_trip_owner(p_trip_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.trips t
    WHERE t.id = p_trip_id
      AND t.user_id = (SELECT auth.uid())
  );
$$;

-- ─── 5. Invite preview (safe token lookup; avoids broad SELECT on trip_invites) ─────────────
CREATE OR REPLACE FUNCTION public.get_invite_preview(invite_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $preview$
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
$preview$;

REVOKE ALL ON FUNCTION public.get_invite_preview(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_invite_preview(text) TO anon, authenticated;

-- ─── 6. accept_invite (row lock + cap 25 accepted collaborators) ────────────────────────
CREATE OR REPLACE FUNCTION public.accept_invite(invite_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $accept$
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
$accept$;

REVOKE ALL ON FUNCTION public.accept_invite(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.accept_invite(text) TO authenticated;

-- ─── 7. Activity log triggers (SECURITY DEFINER inserts; RLS blocks direct client inserts) ─
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

DROP TRIGGER IF EXISTS trip_activities_log_collab ON public.trip_activities;
CREATE TRIGGER trip_activities_log_collab
  AFTER INSERT OR UPDATE OR DELETE ON public.trip_activities
  FOR EACH ROW
  EXECUTE PROCEDURE public.tg_log_trip_activity_changes();

-- ─── 8. RLS ───────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.trip_collaborators ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.trip_invites ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.trip_activity_log ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.trip_collaborators FORCE ROW LEVEL SECURITY;
ALTER TABLE public.trip_invites FORCE ROW LEVEL SECURITY;
ALTER TABLE public.trip_activity_log FORCE ROW LEVEL SECURITY;

-- trip_collaborators
DROP POLICY IF EXISTS trip_collaborators_select ON public.trip_collaborators;
CREATE POLICY trip_collaborators_select
  ON public.trip_collaborators
  FOR SELECT
  TO authenticated
  USING (public.can_view_trip(trip_id));

DROP POLICY IF EXISTS trip_collaborators_insert_owner ON public.trip_collaborators;
CREATE POLICY trip_collaborators_insert_owner
  ON public.trip_collaborators
  FOR INSERT
  TO authenticated
  WITH CHECK (public.is_trip_owner(trip_id));

DROP POLICY IF EXISTS trip_collaborators_update_owner ON public.trip_collaborators;
CREATE POLICY trip_collaborators_update_owner
  ON public.trip_collaborators
  FOR UPDATE
  TO authenticated
  USING (public.is_trip_owner(trip_id))
  WITH CHECK (public.is_trip_owner(trip_id));

DROP POLICY IF EXISTS trip_collaborators_delete_owner_or_self ON public.trip_collaborators;
CREATE POLICY trip_collaborators_delete_owner_or_self
  ON public.trip_collaborators
  FOR DELETE
  TO authenticated
  USING (
    public.is_trip_owner(trip_id)
    OR (
      user_id = (SELECT auth.uid())
      AND status = 'accepted'
    )
  );

-- trip_invites
DROP POLICY IF EXISTS trip_invites_select_owner ON public.trip_invites;
CREATE POLICY trip_invites_select_owner
  ON public.trip_invites
  FOR SELECT
  TO authenticated
  USING (public.is_trip_owner(trip_id));

DROP POLICY IF EXISTS trip_invites_insert_owner ON public.trip_invites;
CREATE POLICY trip_invites_insert_owner
  ON public.trip_invites
  FOR INSERT
  TO authenticated
  WITH CHECK (
    public.is_trip_owner(trip_id)
    AND created_by = (SELECT auth.uid())
  );

DROP POLICY IF EXISTS trip_invites_update_owner ON public.trip_invites;
CREATE POLICY trip_invites_update_owner
  ON public.trip_invites
  FOR UPDATE
  TO authenticated
  USING (public.is_trip_owner(trip_id))
  WITH CHECK (public.is_trip_owner(trip_id));

DROP POLICY IF EXISTS trip_invites_delete_owner ON public.trip_invites;
CREATE POLICY trip_invites_delete_owner
  ON public.trip_invites
  FOR DELETE
  TO authenticated
  USING (public.is_trip_owner(trip_id));

-- trip_activity_log (read-only for clients)
DROP POLICY IF EXISTS trip_activity_log_select ON public.trip_activity_log;
CREATE POLICY trip_activity_log_select
  ON public.trip_activity_log
  FOR SELECT
  TO authenticated
  USING (public.can_view_trip(trip_id));

-- trips: accepted collaborators can read the trip row
DROP POLICY IF EXISTS trips_select_collaborator ON public.trips;
CREATE POLICY trips_select_collaborator
  ON public.trips
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.trip_collaborators tc
      WHERE tc.trip_id = trips.id
        AND tc.user_id = (SELECT auth.uid())
        AND tc.status = 'accepted'
    )
  );

-- Child tables: view trip content as collaborator or owner
DROP POLICY IF EXISTS trip_days_mutate_collaborator ON public.trip_days;
DROP POLICY IF EXISTS trip_days_select_collaborator ON public.trip_days;
CREATE POLICY trip_days_select_collaborator
  ON public.trip_days
  FOR SELECT
  TO authenticated
  USING (public.can_view_trip(trip_id));

DROP POLICY IF EXISTS trip_days_insert_collaborator ON public.trip_days;
CREATE POLICY trip_days_insert_collaborator
  ON public.trip_days
  FOR INSERT
  TO authenticated
  WITH CHECK (public.can_edit_trip(trip_id));

DROP POLICY IF EXISTS trip_days_update_collaborator ON public.trip_days;
CREATE POLICY trip_days_update_collaborator
  ON public.trip_days
  FOR UPDATE
  TO authenticated
  USING (public.can_edit_trip(trip_id))
  WITH CHECK (public.can_edit_trip(trip_id));

DROP POLICY IF EXISTS trip_days_delete_collaborator ON public.trip_days;
CREATE POLICY trip_days_delete_collaborator
  ON public.trip_days
  FOR DELETE
  TO authenticated
  USING (public.can_edit_trip(trip_id));

DROP POLICY IF EXISTS trip_activities_mutate_collaborator ON public.trip_activities;
DROP POLICY IF EXISTS trip_activities_select_collaborator ON public.trip_activities;
CREATE POLICY trip_activities_select_collaborator
  ON public.trip_activities
  FOR SELECT
  TO authenticated
  USING (public.can_view_trip(trip_id));

DROP POLICY IF EXISTS trip_activities_insert_collaborator ON public.trip_activities;
CREATE POLICY trip_activities_insert_collaborator
  ON public.trip_activities
  FOR INSERT
  TO authenticated
  WITH CHECK (public.can_edit_trip(trip_id));

DROP POLICY IF EXISTS trip_activities_update_collaborator ON public.trip_activities;
CREATE POLICY trip_activities_update_collaborator
  ON public.trip_activities
  FOR UPDATE
  TO authenticated
  USING (public.can_edit_trip(trip_id))
  WITH CHECK (public.can_edit_trip(trip_id));

DROP POLICY IF EXISTS trip_activities_delete_collaborator ON public.trip_activities;
CREATE POLICY trip_activities_delete_collaborator
  ON public.trip_activities
  FOR DELETE
  TO authenticated
  USING (public.can_edit_trip(trip_id));

DROP POLICY IF EXISTS trip_bookings_mutate_collaborator ON public.trip_bookings;
DROP POLICY IF EXISTS trip_bookings_select_collaborator ON public.trip_bookings;
CREATE POLICY trip_bookings_select_collaborator
  ON public.trip_bookings
  FOR SELECT
  TO authenticated
  USING (public.can_view_trip(trip_id));

DROP POLICY IF EXISTS trip_bookings_insert_collaborator ON public.trip_bookings;
CREATE POLICY trip_bookings_insert_collaborator
  ON public.trip_bookings
  FOR INSERT
  TO authenticated
  WITH CHECK (public.can_edit_trip(trip_id));

DROP POLICY IF EXISTS trip_bookings_update_collaborator ON public.trip_bookings;
CREATE POLICY trip_bookings_update_collaborator
  ON public.trip_bookings
  FOR UPDATE
  TO authenticated
  USING (public.can_edit_trip(trip_id))
  WITH CHECK (public.can_edit_trip(trip_id));

DROP POLICY IF EXISTS trip_bookings_delete_collaborator ON public.trip_bookings;
CREATE POLICY trip_bookings_delete_collaborator
  ON public.trip_bookings
  FOR DELETE
  TO authenticated
  USING (public.can_edit_trip(trip_id));

-- ─── 9. Realtime (filtered postgres_changes needs REPLICA IDENTITY FULL) ─────────────────
ALTER TABLE public.trip_activities REPLICA IDENTITY FULL;
ALTER TABLE public.trip_days REPLICA IDENTITY FULL;

DO $realtime$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'trip_activities'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.trip_activities;
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'trip_days'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.trip_days;
  END IF;
END
$realtime$;
