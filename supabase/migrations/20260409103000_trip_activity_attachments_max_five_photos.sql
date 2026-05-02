-- Enforce at most 5 image-like attachments per activity (server-side guard; app also checks).

CREATE OR REPLACE FUNCTION public.enforce_trip_activity_max_photos()
RETURNS TRIGGER
LANGUAGE plpgsql
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

DROP TRIGGER IF EXISTS tr_trip_activity_attachments_max_photos ON public.trip_activity_attachments;

CREATE TRIGGER tr_trip_activity_attachments_max_photos
  BEFORE INSERT ON public.trip_activity_attachments
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_trip_activity_max_photos();

COMMENT ON FUNCTION public.enforce_trip_activity_max_photos() IS 'Rejects insert when activity already has 5 image-like attachments.';
