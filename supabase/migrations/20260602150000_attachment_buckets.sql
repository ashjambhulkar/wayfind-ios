-- Wave 1.2 / 1.3 — provision the storage buckets used by the attachment
-- pipeline so `commit-attachment` can mint signed upload URLs without
-- relying on a manual dashboard step.
--
-- Buckets:
--   * `activity-attachments` — already exists (created in remote schema).
--   * `trip-documents`        — already exists.
--   * `booking-attachments`   — NEW (Wave 1.2 / booking attachments).
--   * `expense-receipts`      — NEW (Wave 1.3 / budget receipts).
--
-- All four are private. Reads happen exclusively via service-role-minted
-- signed download URLs (≤60 min TTL) issued by the iOS layer.
--
-- RLS path convention (matches `commit-attachment` Edge Function):
--   <userId>/<tripId>/<parentId>/<random>.<ext>   (activity, expense)
--   <userId>/<bookingId>/<random>.<ext>           (booking)
--   <userId>/trip-documents/<tripId>/<random>.<ext>  (documents)
--
-- We always anchor the first folder segment on the uploader's auth.uid()
-- so a single owner-scoped policy works for INSERT + UPDATE + SELECT +
-- DELETE.

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES
  (
    'booking-attachments',
    'booking-attachments',
    false,
    25 * 1024 * 1024,
    ARRAY[
      'image/jpeg',
      'image/png',
      'image/heic',
      'image/heif',
      'image/webp',
      'application/pdf'
    ]
  ),
  (
    'expense-receipts',
    'expense-receipts',
    false,
    25 * 1024 * 1024,
    ARRAY[
      'image/jpeg',
      'image/png',
      'image/heic',
      'image/heif',
      'image/webp',
      'application/pdf'
    ]
  )
ON CONFLICT (id) DO UPDATE SET
  public = EXCLUDED.public,
  file_size_limit = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

-- Owner-scoped RLS for `booking-attachments`. Path: <userId>/<bookingId>/...
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'storage' AND tablename = 'objects'
      AND policyname = 'booking_attachments_owner_select'
  ) THEN
    CREATE POLICY booking_attachments_owner_select
      ON storage.objects
      FOR SELECT
      TO authenticated
      USING (
        bucket_id = 'booking-attachments'
        AND (storage.foldername(name))[1] = (auth.uid())::text
      );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'storage' AND tablename = 'objects'
      AND policyname = 'booking_attachments_owner_insert'
  ) THEN
    CREATE POLICY booking_attachments_owner_insert
      ON storage.objects
      FOR INSERT
      TO authenticated
      WITH CHECK (
        bucket_id = 'booking-attachments'
        AND (storage.foldername(name))[1] = (auth.uid())::text
      );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'storage' AND tablename = 'objects'
      AND policyname = 'booking_attachments_owner_update'
  ) THEN
    CREATE POLICY booking_attachments_owner_update
      ON storage.objects
      FOR UPDATE
      TO authenticated
      USING (
        bucket_id = 'booking-attachments'
        AND (storage.foldername(name))[1] = (auth.uid())::text
      );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'storage' AND tablename = 'objects'
      AND policyname = 'booking_attachments_owner_delete'
  ) THEN
    CREATE POLICY booking_attachments_owner_delete
      ON storage.objects
      FOR DELETE
      TO authenticated
      USING (
        bucket_id = 'booking-attachments'
        AND (storage.foldername(name))[1] = (auth.uid())::text
      );
  END IF;
END
$$;

-- Owner-scoped RLS for `expense-receipts`. Path: <userId>/<tripId>/<expenseId>/...
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'storage' AND tablename = 'objects'
      AND policyname = 'expense_receipts_owner_select'
  ) THEN
    CREATE POLICY expense_receipts_owner_select
      ON storage.objects
      FOR SELECT
      TO authenticated
      USING (
        bucket_id = 'expense-receipts'
        AND (storage.foldername(name))[1] = (auth.uid())::text
      );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'storage' AND tablename = 'objects'
      AND policyname = 'expense_receipts_owner_insert'
  ) THEN
    CREATE POLICY expense_receipts_owner_insert
      ON storage.objects
      FOR INSERT
      TO authenticated
      WITH CHECK (
        bucket_id = 'expense-receipts'
        AND (storage.foldername(name))[1] = (auth.uid())::text
      );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'storage' AND tablename = 'objects'
      AND policyname = 'expense_receipts_owner_update'
  ) THEN
    CREATE POLICY expense_receipts_owner_update
      ON storage.objects
      FOR UPDATE
      TO authenticated
      USING (
        bucket_id = 'expense-receipts'
        AND (storage.foldername(name))[1] = (auth.uid())::text
      );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'storage' AND tablename = 'objects'
      AND policyname = 'expense_receipts_owner_delete'
  ) THEN
    CREATE POLICY expense_receipts_owner_delete
      ON storage.objects
      FOR DELETE
      TO authenticated
      USING (
        bucket_id = 'expense-receipts'
        AND (storage.foldername(name))[1] = (auth.uid())::text
      );
  END IF;
END
$$;

-- RLS for the trip_booking_attachments rows (owner-scoped, mirrors
-- `Owner full access to activity attachments` from the remote schema).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'trip_booking_attachments'
      AND policyname = 'Owner full access to booking attachments'
  ) THEN
    CREATE POLICY "Owner full access to booking attachments"
      ON public.trip_booking_attachments
      AS PERMISSIVE
      FOR ALL
      TO authenticated
      USING (user_id = auth.uid())
      WITH CHECK (user_id = auth.uid());
  END IF;
END
$$;
