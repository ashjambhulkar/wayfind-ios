-- Wave 1.4 — categorize trip documents (visa, insurance, hotel, flight,
-- transport, other) so the iOS list can show category chips. The
-- commit-attachment Edge Function already writes this column when callers
-- pass `category` in the body; this migration just makes it persistable.
--
-- We use a TEXT column with a CHECK constraint instead of an enum because
-- (a) Supabase RLS plays nicer with text comparisons, and (b) we can add
-- a new bucket without a migration roundtrip in the future.

ALTER TABLE public.trip_documents
  ADD COLUMN IF NOT EXISTS category text;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.constraint_column_usage
    WHERE table_schema = 'public'
      AND table_name = 'trip_documents'
      AND constraint_name = 'trip_documents_category_check'
  ) THEN
    ALTER TABLE public.trip_documents
      ADD CONSTRAINT trip_documents_category_check
      CHECK (
        category IS NULL
        OR category IN (
          'visa',
          'insurance',
          'lodging',
          'flight',
          'transport',
          'tickets',
          'other'
        )
      );
  END IF;
END
$$;

CREATE INDEX IF NOT EXISTS trip_documents_trip_category_idx
  ON public.trip_documents (trip_id, category);

COMMENT ON COLUMN public.trip_documents.category IS
  'User-selected category. Used by the iOS chips filter. Wave 1.4.';

-- Wave 1.4 GC trigger — make sure we enqueue storage deletion when the
-- document row is removed (mirrors the activity / booking / expense path).
CREATE OR REPLACE FUNCTION public.tr_trip_documents_enqueue_storage_delete()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.storage_path IS NOT NULL THEN
    PERFORM public.enqueue_storage_deletion(
      'trip-documents',
      OLD.storage_path,
      'trip_documents',
      OLD.id
    );
  END IF;
  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS tr_trip_documents_enqueue_storage_delete
  ON public.trip_documents;
CREATE TRIGGER tr_trip_documents_enqueue_storage_delete
  BEFORE DELETE ON public.trip_documents
  FOR EACH ROW
  EXECUTE FUNCTION public.tr_trip_documents_enqueue_storage_delete();
