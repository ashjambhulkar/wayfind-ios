-- Wave 1.3 — receipts for `trip_expenses`. Mirrors `trip_activity_attachments`
-- so the iOS BackgroundUploader pipeline (commit-attachment Edge Function +
-- pending_storage_deletions GC) works without surface-specific branches.
--
-- Why a separate table instead of a `receipt_url` column on `trip_expenses`?
--   * Multiple receipts per expense (think dinner + tip slip).
--   * Soft-delete safety: clearing the column would orphan the storage object
--     because the BEFORE-DELETE trigger only fires on row deletes.
--   * Symmetry with activity / booking attachments lets us reuse the entire
--     iOS Wave 1 attachment chassis.

CREATE TABLE IF NOT EXISTS public.trip_expense_attachments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  expense_id uuid NOT NULL REFERENCES public.trip_expenses (id) ON DELETE CASCADE,
  trip_id uuid NOT NULL REFERENCES public.trips (id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  storage_path text NOT NULL,
  original_filename text,
  mime_type text,
  file_size_bytes integer CHECK (file_size_bytes IS NULL OR file_size_bytes >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_trip_expense_attachments_expense
  ON public.trip_expense_attachments (expense_id);

CREATE INDEX IF NOT EXISTS idx_trip_expense_attachments_trip
  ON public.trip_expense_attachments (trip_id);

CREATE INDEX IF NOT EXISTS idx_trip_expense_attachments_user
  ON public.trip_expense_attachments (user_id);

-- Mirror the `set_*_updated_at` convention used elsewhere.
DROP TRIGGER IF EXISTS set_trip_expense_attachments_updated_at
  ON public.trip_expense_attachments;
CREATE TRIGGER set_trip_expense_attachments_updated_at
  BEFORE UPDATE ON public.trip_expense_attachments
  FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at();

-- Mirror Wave 0's GC trigger for activity / booking attachments.
CREATE OR REPLACE FUNCTION public.tr_trip_expense_attachments_enqueue_storage_delete()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.storage_path IS NOT NULL THEN
    PERFORM public.enqueue_storage_deletion(
      'expense-receipts',
      OLD.storage_path,
      'trip_expense_attachments',
      OLD.id
    );
  END IF;
  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS tr_trip_expense_attachments_enqueue_storage_delete
  ON public.trip_expense_attachments;
CREATE TRIGGER tr_trip_expense_attachments_enqueue_storage_delete
  BEFORE DELETE ON public.trip_expense_attachments
  FOR EACH ROW
  EXECUTE FUNCTION public.tr_trip_expense_attachments_enqueue_storage_delete();

-- RLS — owner-scoped, mirrors the activity / booking policies.
ALTER TABLE public.trip_expense_attachments ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'trip_expense_attachments'
      AND policyname = 'Owner full access to expense attachments'
  ) THEN
    CREATE POLICY "Owner full access to expense attachments"
      ON public.trip_expense_attachments
      AS PERMISSIVE
      FOR ALL
      TO authenticated
      USING (user_id = auth.uid())
      WITH CHECK (user_id = auth.uid());
  END IF;

  -- Trip collaborators with edit rights can view receipts (they likely
  -- helped pay) but only the uploader can mutate the row.
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'trip_expense_attachments'
      AND policyname = 'Trip collaborators can view expense attachments'
  ) THEN
    CREATE POLICY "Trip collaborators can view expense attachments"
      ON public.trip_expense_attachments
      AS PERMISSIVE
      FOR SELECT
      TO authenticated
      USING (
        EXISTS (
          SELECT 1
          FROM public.trip_collaborators tc
          WHERE tc.trip_id = trip_expense_attachments.trip_id
            AND tc.user_id = auth.uid()
        )
      );
  END IF;
END
$$;

COMMENT ON TABLE public.trip_expense_attachments IS
  'Receipt photos / PDFs for trip_expenses. Bytes live in Supabase Storage bucket `expense-receipts`. Wave 1.3.';
