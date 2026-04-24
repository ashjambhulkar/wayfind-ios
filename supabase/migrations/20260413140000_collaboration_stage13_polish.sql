-- Stage 13: pending invite decline audit + Realtime on trip_collaborators (removed-user kick on client).

-- ─── Allow new activity log action ───────────────────────────────────────────
ALTER TABLE public.trip_activity_log
  DROP CONSTRAINT IF EXISTS trip_activity_log_action_check;

ALTER TABLE public.trip_activity_log
  ADD CONSTRAINT trip_activity_log_action_check CHECK (
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
      'trip_updated',
      'pending_invite_declined'
    )
  );

-- ─── Log when invitee removes their own pending row (decline) ────────────────
-- Owner revoking a pending row: auth.uid() <> OLD.user_id → no log (no false “declined”).
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

DROP TRIGGER IF EXISTS trip_collaborators_log_pending_decline ON public.trip_collaborators;
CREATE TRIGGER trip_collaborators_log_pending_decline
  AFTER DELETE ON public.trip_collaborators
  FOR EACH ROW
  EXECUTE PROCEDURE public.tg_log_pending_invite_declined();

-- ─── Realtime: collaborator row deletes (for “removed while viewing” client UX) ─
ALTER TABLE public.trip_collaborators REPLICA IDENTITY FULL;

DO $realtime$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'trip_collaborators'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.trip_collaborators;
  END IF;
END
$realtime$;
