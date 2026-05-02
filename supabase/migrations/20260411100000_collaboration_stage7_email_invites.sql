-- Stage 7: email invites — pending invitees can view trip (read-only until accept),
-- service-only email lookup, accept_pending_collaborator RPC, optional invited_email on trip_invites.

-- ─── 1. trip_invites: target email for link-based email invites (resend / dedup) ────────────
ALTER TABLE public.trip_invites
  ADD COLUMN IF NOT EXISTS invited_email text;

CREATE INDEX IF NOT EXISTS idx_trip_invites_trip_invited_email
  ON public.trip_invites (trip_id, (lower(trim(invited_email))))
  WHERE invited_email IS NOT NULL AND is_active = true;

-- ─── 2. can_view_trip: allow pending collaborators (preview until accept/decline) ─────────
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
      AND tc.status IN ('accepted', 'pending')
  );
$$;

-- ─── 3. Pending invitee may remove their own pending row (decline) ────────────────────────
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
    OR (
      user_id = (SELECT auth.uid())
      AND status = 'pending'
    )
  );

-- ─── 4. Service role only: resolve auth user id by email (Edge Functions) ───────────────
CREATE OR REPLACE FUNCTION public.lookup_auth_user_id_by_email(p_email text)
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = auth, public
AS $$
  SELECT u.id
  FROM auth.users u
  WHERE lower(trim(u.email::text)) = lower(trim(p_email))
  LIMIT 1;
$$;

REVOKE ALL ON FUNCTION public.lookup_auth_user_id_by_email(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.lookup_auth_user_id_by_email(text) TO service_role;

-- ─── 5. Accept in-app email invite (pending → accepted) ──────────────────────────────────
CREATE OR REPLACE FUNCTION public.accept_pending_collaborator(p_trip_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
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
$fn$;

REVOKE ALL ON FUNCTION public.accept_pending_collaborator(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.accept_pending_collaborator(uuid) TO authenticated;
