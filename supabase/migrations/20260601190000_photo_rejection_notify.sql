-- Phase F.7 — Surface rejection notices to the uploader + open the
-- DSA-compliant appeal hook. The pipeline is:
--
--   1. `place_user_photos.status` flips to 'rejected' (or 'pending_review'
--      when human moderation is required).
--   2. A trigger inserts a row into `place_user_photo_events` — a thin
--      audit log iOS reads to surface "Your recent photos" with their
--      current status & reason.
--   3. A separate worker (push-notify-photo-rejection Edge Function,
--      hooked in a follow-up) consumes the event log and dispatches a
--      push notification. We persist events even if push delivery is
--      offline so the user always sees the verdict on next launch.
--
-- DSA Article 17 (Statement of Reasons) requires we tell the uploader
-- *why* their content was acted on; the `reason` + `detail` columns on
-- `place_user_photos` already carry that, and this event log is the
-- transport. Article 20 requires an internal complaint mechanism — that
-- is `dsa_appeals` from the F.1 migration, surfaced via the
-- `submit_dsa_appeal` RPC below.

CREATE TABLE IF NOT EXISTS public.place_user_photo_events (
  id bigserial PRIMARY KEY,
  photo_id uuid NOT NULL REFERENCES public.place_user_photos (id) ON DELETE CASCADE,
  uploader_user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  status text NOT NULL,
  reason text,
  detail text,
  created_at timestamptz NOT NULL DEFAULT now(),
  acknowledged_at timestamptz
);

CREATE INDEX IF NOT EXISTS place_user_photo_events_user_unack_idx
  ON public.place_user_photo_events (uploader_user_id, created_at DESC)
  WHERE acknowledged_at IS NULL;

ALTER TABLE public.place_user_photo_events ENABLE ROW LEVEL SECURITY;

-- Uploader sees only their own events. Acknowledgement updates flow
-- through the dedicated RPC below.
CREATE POLICY place_user_photo_events_self_read ON public.place_user_photo_events
  FOR SELECT USING (uploader_user_id = auth.uid());

GRANT SELECT ON public.place_user_photo_events TO authenticated;

CREATE OR REPLACE FUNCTION public.emit_photo_event()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Only emit when the status materially changes. Skip
  -- pending_moderation → pending_moderation no-ops.
  IF TG_OP = 'UPDATE' AND OLD.status IS NOT DISTINCT FROM NEW.status THEN
    RETURN NEW;
  END IF;
  IF NEW.status NOT IN ('approved', 'rejected', 'pending_review', 'reported', 'removed') THEN
    RETURN NEW;
  END IF;

  INSERT INTO public.place_user_photo_events (
    photo_id, uploader_user_id, status, reason, detail
  ) VALUES (
    NEW.id, NEW.uploader_user_id, NEW.status, NEW.reject_reason, NEW.reject_detail
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS place_user_photos_emit_event ON public.place_user_photos;
CREATE TRIGGER place_user_photos_emit_event
  AFTER INSERT OR UPDATE OF status
  ON public.place_user_photos
  FOR EACH ROW
  EXECUTE FUNCTION public.emit_photo_event();

-- Acknowledgement RPC — iOS calls this once the user has read the
-- rejection reason, so we don't keep nagging them in the badge UI.
CREATE OR REPLACE FUNCTION public.acknowledge_photo_event(p_event_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.place_user_photo_events
     SET acknowledged_at = now()
   WHERE id = p_event_id
     AND uploader_user_id = auth.uid();
END;
$$;

GRANT EXECUTE ON FUNCTION public.acknowledge_photo_event(bigint)
  TO authenticated;

-- Phase F.7 — DSA-compliant appeal submission. Inserts into
-- `dsa_appeals` (created in F.1) with status='open'. Once a moderator
-- resolves, status flips to 'accepted' or 'rejected' via service-role
-- workflow. The submitter cannot mutate that field.
CREATE OR REPLACE FUNCTION public.submit_dsa_appeal(
  p_photo_id uuid,
  p_appeal_text text
)
RETURNS public.dsa_appeals
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uploader uuid;
  v_row public.dsa_appeals;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = '42501';
  END IF;
  IF p_photo_id IS NULL THEN
    RAISE EXCEPTION 'missing_photo_id' USING ERRCODE = '22023';
  END IF;

  SELECT uploader_user_id
    INTO v_uploader
    FROM public.place_user_photos
   WHERE id = p_photo_id;
  IF v_uploader IS NULL THEN
    RAISE EXCEPTION 'photo_not_found' USING ERRCODE = '02000';
  END IF;
  IF v_uploader <> auth.uid() THEN
    RAISE EXCEPTION 'not_uploader' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.dsa_appeals (photo_id, uploader_user_id, appeal_text)
  VALUES (p_photo_id, auth.uid(), NULLIF(trim(p_appeal_text), ''))
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

GRANT EXECUTE ON FUNCTION public.submit_dsa_appeal(uuid, text)
  TO authenticated;
