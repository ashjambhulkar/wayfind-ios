-- Trip-scoped user documents in `trip-documents` at `{user_id}/trip-documents/{trip_id}/{object_name}`.
-- Idempotent: safe when the table already exists on a remote that was provisioned manually.

CREATE TABLE IF NOT EXISTS public.trip_documents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  trip_id uuid NOT NULL REFERENCES public.trips (id) ON DELETE CASCADE,
  uploaded_by uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  storage_path text NOT NULL UNIQUE,
  file_name text NOT NULL,
  mime_type text NOT NULL,
  byte_size bigint NOT NULL CHECK (byte_size >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  title text NULL
);

CREATE INDEX IF NOT EXISTS trip_documents_trip_created_idx ON public.trip_documents (trip_id, created_at DESC);
CREATE INDEX IF NOT EXISTS trip_documents_uploaded_by_idx ON public.trip_documents (uploaded_by);

COMMENT ON TABLE public.trip_documents IS 'Metadata for trip files in Storage bucket trip-documents under userId/trip-documents/tripId/.';

ALTER TABLE public.trip_documents ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS trip_documents_select_viewers ON public.trip_documents;
CREATE POLICY trip_documents_select_viewers
  ON public.trip_documents
  FOR SELECT
  TO authenticated
  USING (public.can_view_trip(trip_id));

DROP POLICY IF EXISTS trip_documents_insert_editors ON public.trip_documents;
CREATE POLICY trip_documents_insert_editors
  ON public.trip_documents
  FOR INSERT
  TO authenticated
  WITH CHECK (
    public.can_edit_trip(trip_id)
    AND uploaded_by = (SELECT auth.uid())
  );

DROP POLICY IF EXISTS trip_documents_update_editors ON public.trip_documents;
CREATE POLICY trip_documents_update_editors
  ON public.trip_documents
  FOR UPDATE
  TO authenticated
  USING (public.can_edit_trip(trip_id))
  WITH CHECK (public.can_edit_trip(trip_id));

DROP POLICY IF EXISTS trip_documents_delete_editors ON public.trip_documents;
CREATE POLICY trip_documents_delete_editors
  ON public.trip_documents
  FOR DELETE
  TO authenticated
  USING (public.can_edit_trip(trip_id));

-- Storage: objects under trip-documents/{userId}/trip-documents/{tripId}/...
-- Bucket `trip-documents` must exist. Review other bucket policies if uploads fail unexpectedly.

DROP POLICY IF EXISTS trip_documents_storage_select ON storage.objects;
CREATE POLICY trip_documents_storage_select
  ON storage.objects
  FOR SELECT
  TO authenticated
  USING (
    bucket_id = 'trip-documents'
    AND array_length(string_to_array(name, '/'), 1) >= 4
    AND (string_to_array(name, '/'))[2] = 'trip-documents'
    AND (string_to_array(name, '/'))[3] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    AND public.can_view_trip(((string_to_array(name, '/'))[3])::uuid)
  );

DROP POLICY IF EXISTS trip_documents_storage_insert ON storage.objects;
CREATE POLICY trip_documents_storage_insert
  ON storage.objects
  FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'trip-documents'
    AND array_length(string_to_array(name, '/'), 1) >= 4
    AND (string_to_array(name, '/'))[1] = (SELECT auth.uid())::text
    AND (string_to_array(name, '/'))[2] = 'trip-documents'
    AND (string_to_array(name, '/'))[3] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    AND public.can_edit_trip(((string_to_array(name, '/'))[3])::uuid)
  );

DROP POLICY IF EXISTS trip_documents_storage_delete ON storage.objects;
CREATE POLICY trip_documents_storage_delete
  ON storage.objects
  FOR DELETE
  TO authenticated
  USING (
    bucket_id = 'trip-documents'
    AND array_length(string_to_array(name, '/'), 1) >= 4
    AND (string_to_array(name, '/'))[2] = 'trip-documents'
    AND (string_to_array(name, '/'))[3] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    AND public.can_edit_trip(((string_to_array(name, '/'))[3])::uuid)
  );
