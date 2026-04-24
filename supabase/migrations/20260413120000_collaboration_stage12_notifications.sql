-- Stage 12: collaboration push + in-app notifications (Finding 15 / plan §8).
--
-- After deploy, create a Database Webhook (Dashboard → Integrations → Webhooks):
--   Table: public.trip_activity_log, Event: INSERT
--   URL:  https://<PROJECT_REF>.supabase.co/functions/v1/collaboration-notify
--   HTTP Headers: Content-Type: application/json
--                 X-Wayfind-Collab-Secret: <same value as Edge secret WAYFIND_COLLAB_NOTIFY_SECRET>
-- Set Edge secret WAYFIND_COLLAB_NOTIFY_SECRET on the collaboration-notify function.

-- ─── Push throttle: max one batched push per trip per recipient per 5 minutes ─
CREATE TABLE IF NOT EXISTS public.collaboration_push_throttle (
  trip_id uuid NOT NULL REFERENCES public.trips (id) ON DELETE CASCADE,
  user_id uuid NOT NULL,
  last_push_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (trip_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_collaboration_push_throttle_user
  ON public.collaboration_push_throttle (user_id);

COMMENT ON TABLE public.collaboration_push_throttle IS
  'Stage 12: debounce batched trip-activity pushes (5 min window per recipient per trip).';

ALTER TABLE public.collaboration_push_throttle ENABLE ROW LEVEL SECURITY;

-- No policies: clients use RLS; service role (Edge Functions) bypasses RLS.

-- ─── Distinguish voluntary leave vs owner removal (for notifications) ───────
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
