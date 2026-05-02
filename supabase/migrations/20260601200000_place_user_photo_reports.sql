-- Phase F.8 — Long-press → "Report photo" flow on user-uploaded photos.
--
-- Mirrors Phase E (city_place_reports) but operates on individual
-- `place_user_photos` rows. Three distinct reporters trigger an
-- automatic flip back to `pending_review`, returning the photo to the
-- moderation queue. We avoid auto-rejecting outright because review
-- bombing is a real attack surface; a moderator decides what to do
-- with the queued item.

CREATE TABLE IF NOT EXISTS public.place_user_photo_reports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  photo_id uuid NOT NULL REFERENCES public.place_user_photos (id) ON DELETE CASCADE,
  reporter_user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  reason text NOT NULL CHECK (reason IN (
    'inappropriate', 'misleading', 'spam_or_ad', 'other'
  )),
  details text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT place_user_photo_reports_unique_per_user UNIQUE (photo_id, reporter_user_id)
);

CREATE INDEX IF NOT EXISTS place_user_photo_reports_photo_idx
  ON public.place_user_photo_reports (photo_id, created_at DESC);

ALTER TABLE public.place_user_photo_reports ENABLE ROW LEVEL SECURITY;

-- Reporters can see only their own reports (so the UI can show
-- "Reported" state). Service role inspects everything for moderation.
CREATE POLICY place_user_photo_reports_self_read
  ON public.place_user_photo_reports
  FOR SELECT USING (reporter_user_id = auth.uid());

GRANT SELECT ON public.place_user_photo_reports TO authenticated;

-- Insert RPC. SECURITY DEFINER so we can read the current report count
-- (which RLS-restricted SELECT would otherwise hide) and conditionally
-- flip the photo's status atomically. Idempotent per (photo, user,
-- reason) via the UNIQUE index — calling it twice with the same
-- arguments is a no-op.
CREATE OR REPLACE FUNCTION public.report_user_photo(
  p_photo_id uuid,
  p_reason text,
  p_details text DEFAULT NULL
)
RETURNS TABLE (report_count integer, escalated boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uploader uuid;
  v_status text;
  v_count integer;
  v_escalated boolean := false;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = '42501';
  END IF;
  IF p_reason NOT IN ('inappropriate', 'misleading', 'spam_or_ad', 'other') THEN
    RAISE EXCEPTION 'invalid_reason' USING ERRCODE = '22023';
  END IF;

  SELECT uploader_user_id, status
    INTO v_uploader, v_status
    FROM public.place_user_photos
   WHERE id = p_photo_id;
  IF v_uploader IS NULL THEN
    RAISE EXCEPTION 'photo_not_found' USING ERRCODE = '02000';
  END IF;
  -- A user cannot report their own photo. Prevents griefing where
  -- self-reports artificially inflate the queue.
  IF v_uploader = auth.uid() THEN
    RAISE EXCEPTION 'cannot_report_own_photo' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.place_user_photo_reports (
    photo_id, reporter_user_id, reason, details
  ) VALUES (
    p_photo_id, auth.uid(), p_reason, NULLIF(trim(p_details), '')
  )
  ON CONFLICT (photo_id, reporter_user_id) DO UPDATE
    SET reason = EXCLUDED.reason,
        details = EXCLUDED.details;

  SELECT count(DISTINCT reporter_user_id)::integer
    INTO v_count
    FROM public.place_user_photo_reports
   WHERE photo_id = p_photo_id;

  -- Threshold flip: at 3 distinct reporters we send the photo back to
  -- the moderation queue if it's currently approved. Already-pending or
  -- rejected photos are left alone.
  IF v_count >= 3 AND v_status = 'approved' THEN
    UPDATE public.place_user_photos
       SET status = 'pending_review',
           reject_reason = COALESCE(reject_reason, 'community_reports'),
           reject_detail = 'Flagged by multiple community members.'
     WHERE id = p_photo_id;
    v_escalated := true;
  END IF;

  report_count := v_count;
  escalated := v_escalated;
  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION public.report_user_photo(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.report_user_photo(uuid, text, text)
  TO authenticated, service_role;
