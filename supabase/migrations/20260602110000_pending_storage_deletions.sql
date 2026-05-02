-- Wave 0 (shared infra) — pending_storage_deletions queue + nightly GC.
--
-- Plan §0.5 E6: deleting a `trip_documents` / attachment row leaves the
-- storage object orphaned. Strategy:
--   1. BEFORE DELETE triggers on every attachment table push the bucket+path
--      into this queue.
--   2. The `gc-storage-objects` Edge Function (next file) drains the queue
--      nightly via pg_cron, calling Supabase Storage REST to remove objects.
--
-- Idempotent: requeueing the same path twice is harmless because the GC
-- function treats not_found as success.

CREATE TABLE IF NOT EXISTS public.pending_storage_deletions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  bucket text NOT NULL,
  storage_path text NOT NULL,
  source_table text NOT NULL,
  source_row_id uuid,
  enqueued_at timestamptz NOT NULL DEFAULT now(),
  attempted_at timestamptz,
  attempts integer NOT NULL DEFAULT 0,
  last_error text,
  succeeded_at timestamptz
);

CREATE INDEX IF NOT EXISTS pending_storage_deletions_unprocessed_idx
  ON public.pending_storage_deletions (enqueued_at)
  WHERE succeeded_at IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS pending_storage_deletions_uniq_active_idx
  ON public.pending_storage_deletions (bucket, storage_path)
  WHERE succeeded_at IS NULL;

COMMENT ON TABLE public.pending_storage_deletions IS
  'Wave 0 — orphan-storage GC queue. Drained by gc-storage-objects Edge Function.';

ALTER TABLE public.pending_storage_deletions ENABLE ROW LEVEL SECURITY;

-- Service-role only. The trigger inserts run as SECURITY DEFINER so they
-- bypass RLS even if the original DELETE was issued by an authenticated
-- client. No client-facing policies on this table by design.

CREATE OR REPLACE FUNCTION public.enqueue_storage_deletion(
  p_bucket text,
  p_path text,
  p_source_table text,
  p_source_row_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
BEGIN
  IF p_bucket IS NULL OR p_path IS NULL OR length(trim(p_path)) = 0 THEN
    RETURN;
  END IF;

  INSERT INTO public.pending_storage_deletions (bucket, storage_path, source_table, source_row_id)
  VALUES (p_bucket, p_path, p_source_table, p_source_row_id)
  ON CONFLICT DO NOTHING;
END
$fn$;

REVOKE ALL ON FUNCTION public.enqueue_storage_deletion(text, text, text, uuid) FROM PUBLIC;

-- ─── Wire each attachment table's BEFORE DELETE trigger ─────────────────

-- trip_documents (storage_path is full object key in `trip-documents` bucket)
CREATE OR REPLACE FUNCTION public.tr_trip_documents_enqueue_storage_delete()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
BEGIN
  IF OLD.storage_path IS NOT NULL THEN
    PERFORM public.enqueue_storage_deletion(
      'trip-documents', OLD.storage_path, 'trip_documents', OLD.id
    );
  END IF;
  RETURN OLD;
END
$fn$;

DROP TRIGGER IF EXISTS trip_documents_storage_gc ON public.trip_documents;
CREATE TRIGGER trip_documents_storage_gc
  BEFORE DELETE ON public.trip_documents
  FOR EACH ROW
  EXECUTE FUNCTION public.tr_trip_documents_enqueue_storage_delete();

-- trip_activity_attachments (bucket activity-attachments)
CREATE OR REPLACE FUNCTION public.tr_trip_activity_attachments_enqueue_storage_delete()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
BEGIN
  IF OLD.storage_path IS NOT NULL THEN
    PERFORM public.enqueue_storage_deletion(
      'activity-attachments', OLD.storage_path, 'trip_activity_attachments', OLD.id
    );
  END IF;
  RETURN OLD;
END
$fn$;

DROP TRIGGER IF EXISTS trip_activity_attachments_storage_gc ON public.trip_activity_attachments;
CREATE TRIGGER trip_activity_attachments_storage_gc
  BEFORE DELETE ON public.trip_activity_attachments
  FOR EACH ROW
  EXECUTE FUNCTION public.tr_trip_activity_attachments_enqueue_storage_delete();

-- trip_booking_attachments (bucket booking-attachments)
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'trip_booking_attachments') THEN
    EXECUTE $sql$
      CREATE OR REPLACE FUNCTION public.tr_trip_booking_attachments_enqueue_storage_delete()
      RETURNS trigger
      LANGUAGE plpgsql
      SECURITY DEFINER
      SET search_path = public
      AS $fn$
      BEGIN
        IF OLD.storage_path IS NOT NULL THEN
          PERFORM public.enqueue_storage_deletion(
            'booking-attachments', OLD.storage_path, 'trip_booking_attachments', OLD.id
          );
        END IF;
        RETURN OLD;
      END
      $fn$;
    $sql$;
    EXECUTE 'DROP TRIGGER IF EXISTS trip_booking_attachments_storage_gc ON public.trip_booking_attachments';
    EXECUTE 'CREATE TRIGGER trip_booking_attachments_storage_gc BEFORE DELETE ON public.trip_booking_attachments FOR EACH ROW EXECUTE FUNCTION public.tr_trip_booking_attachments_enqueue_storage_delete()';
  END IF;
END $$;
