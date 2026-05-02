-- Trip documents: max 15 per trip, max 10 MB per file (aligned with app + commit-attachment).

CREATE OR REPLACE FUNCTION public.enforce_trip_documents_limits()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  cnt integer;
BEGIN
  SELECT COUNT(*)::integer
  INTO cnt
  FROM public.trip_documents
  WHERE trip_id = NEW.trip_id;

  IF cnt >= 15 THEN
    RAISE EXCEPTION 'TRIP_DOCUMENT_LIMIT'
      USING DETAIL = 'Maximum 15 documents per trip.';
  END IF;

  IF NEW.byte_size > 10485760 THEN
    RAISE EXCEPTION 'TRIP_DOCUMENT_FILE_TOO_LARGE'
      USING DETAIL = 'Maximum 10 MB per document.';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS tr_trip_documents_limits ON public.trip_documents;

CREATE TRIGGER tr_trip_documents_limits
  BEFORE INSERT ON public.trip_documents
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_trip_documents_limits();

COMMENT ON FUNCTION public.enforce_trip_documents_limits() IS
  'Rejects insert when trip already has 15 documents or byte_size exceeds 10 MB.';
