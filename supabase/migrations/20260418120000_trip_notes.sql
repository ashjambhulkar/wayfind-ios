-- Trip notes (V2a depth). RLS: view = can_view_trip, mutate = can_edit_trip.

CREATE TABLE IF NOT EXISTS public.trip_notes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  trip_id uuid NOT NULL REFERENCES public.trips (id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  title text NOT NULL DEFAULT '',
  body text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS trip_notes_trip_updated_idx ON public.trip_notes (trip_id, updated_at DESC);

COMMENT ON TABLE public.trip_notes IS 'Per-trip freeform notes; title + body, sorted by updated_at.';

CREATE OR REPLACE FUNCTION public.trip_notes_bump_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trip_notes_set_updated_at ON public.trip_notes;
CREATE TRIGGER trip_notes_set_updated_at
  BEFORE UPDATE ON public.trip_notes
  FOR EACH ROW
  EXECUTE PROCEDURE public.trip_notes_bump_updated_at();

ALTER TABLE public.trip_notes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS trip_notes_select_viewers ON public.trip_notes;
CREATE POLICY trip_notes_select_viewers
  ON public.trip_notes
  FOR SELECT
  TO authenticated
  USING (public.can_view_trip(trip_id));

DROP POLICY IF EXISTS trip_notes_insert_editors ON public.trip_notes;
CREATE POLICY trip_notes_insert_editors
  ON public.trip_notes
  FOR INSERT
  TO authenticated
  WITH CHECK (
    public.can_edit_trip(trip_id)
    AND user_id = (SELECT auth.uid())
  );

DROP POLICY IF EXISTS trip_notes_update_editors ON public.trip_notes;
CREATE POLICY trip_notes_update_editors
  ON public.trip_notes
  FOR UPDATE
  TO authenticated
  USING (public.can_edit_trip(trip_id))
  WITH CHECK (public.can_edit_trip(trip_id));

DROP POLICY IF EXISTS trip_notes_delete_editors ON public.trip_notes;
CREATE POLICY trip_notes_delete_editors
  ON public.trip_notes
  FOR DELETE
  TO authenticated
  USING (public.can_edit_trip(trip_id));
