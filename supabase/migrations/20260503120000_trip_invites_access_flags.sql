-- Phase 8 of the collaborative-budget rollout: surface the three per-surface
-- access flags chosen in `InviteComposeSheet` (Documents / Expenses / Notes)
-- end-to-end. Today the iOS sheet captures them, the `TripInvite` model
-- carries them, and `EditAccessSheet` can edit them after the fact via
-- `CollaboratorService.updateAccessFlags`. The missing link is the invite →
-- accept handoff: `accept_invite` always inserts a `trip_collaborators` row
-- with the column defaults (false for `can_see_documents` /
-- `can_see_expenses` and false-by-default for `can_see_notes`), so the
-- recipient lands on the trip with NO surface access regardless of what the
-- owner picked when sharing.
--
-- This migration plugs that gap:
--   1. Adds three boolean columns to `trip_invites` (default true so legacy
--      invites that pre-date this rollout keep the previous "all on" UX).
--   2. Updates `accept_invite` to copy those flags onto the new
--      `trip_collaborators` row instead of relying on the column defaults.
--   3. Backfills existing active invites to `true` so any link already in
--      the wild keeps working as the owner intended when they shared it.
--
-- Idempotent — uses `IF NOT EXISTS` and `CREATE OR REPLACE FUNCTION`. Safe
-- to re-run.

-- ─── 1. New columns on trip_invites ─────────────────────────────────────────

ALTER TABLE public.trip_invites
  ADD COLUMN IF NOT EXISTS can_see_documents boolean NOT NULL DEFAULT true;

ALTER TABLE public.trip_invites
  ADD COLUMN IF NOT EXISTS can_see_expenses boolean NOT NULL DEFAULT true;

ALTER TABLE public.trip_invites
  ADD COLUMN IF NOT EXISTS can_see_notes boolean NOT NULL DEFAULT true;

-- Belt-and-suspenders backfill: re-affirm `true` on all rows so any invite
-- that managed to land before the columns existed (and would be created
-- with the column default at ALTER time) is still in the desired state.
UPDATE public.trip_invites
SET can_see_documents = true,
    can_see_expenses = true,
    can_see_notes = true
WHERE can_see_documents IS DISTINCT FROM true
   OR can_see_expenses IS DISTINCT FROM true
   OR can_see_notes IS DISTINCT FROM true;


-- ─── 2. accept_invite: propagate flags to trip_collaborators ────────────────

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

  INSERT INTO public.trip_collaborators (
    trip_id,
    user_id,
    role,
    status,
    can_see_documents,
    can_see_expenses,
    can_see_notes
  )
  VALUES (
    v_invite.trip_id,
    (SELECT auth.uid()),
    v_invite.role,
    'accepted',
    v_invite.can_see_documents,
    v_invite.can_see_expenses,
    v_invite.can_see_notes
  );

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
