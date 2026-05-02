-- Trip checklists + items (V2a depth). RLS: view = can_view_trip, mutate = can_edit_trip.
-- Idempotent: safe when objects already exist on a remote provisioned outside migration history.

CREATE TABLE IF NOT EXISTS public.trip_checklists (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  trip_id uuid NOT NULL REFERENCES public.trips (id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  title text NOT NULL,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS trip_checklists_trip_sort_idx ON public.trip_checklists (trip_id, sort_order);

CREATE TABLE IF NOT EXISTS public.checklist_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  checklist_id uuid NOT NULL REFERENCES public.trip_checklists (id) ON DELETE CASCADE,
  trip_id uuid NOT NULL REFERENCES public.trips (id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  title text NOT NULL,
  is_done boolean NOT NULL DEFAULT false,
  sort_order integer NOT NULL DEFAULT 0,
  due_at timestamptz NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- Legacy DBs may have checklist_items without trip_id (RLS + indexes expect it).
ALTER TABLE public.checklist_items
  ADD COLUMN IF NOT EXISTS trip_id uuid REFERENCES public.trips (id) ON DELETE CASCADE;

UPDATE public.checklist_items ci
SET trip_id = c.trip_id
FROM public.trip_checklists c
WHERE ci.checklist_id = c.id
  AND ci.trip_id IS NULL;

ALTER TABLE public.checklist_items
  ALTER COLUMN trip_id SET NOT NULL;

CREATE INDEX IF NOT EXISTS checklist_items_checklist_sort_idx ON public.checklist_items (checklist_id, sort_order);
CREATE INDEX IF NOT EXISTS checklist_items_trip_idx ON public.checklist_items (trip_id);

COMMENT ON TABLE public.trip_checklists IS 'Per-trip packing / to-do lists.';
COMMENT ON TABLE public.checklist_items IS 'Rows in a trip checklist; trip_id denormalized for RLS.';

CREATE OR REPLACE FUNCTION public.checklist_items_sync_trip_id()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_trip uuid;
BEGIN
  SELECT c.trip_id INTO v_trip
  FROM public.trip_checklists c
  WHERE c.id = NEW.checklist_id;
  IF v_trip IS NULL THEN
    RAISE EXCEPTION 'checklist_id % not found', NEW.checklist_id;
  END IF;
  NEW.trip_id := v_trip;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS checklist_items_sync_trip_id_trigger ON public.checklist_items;
CREATE TRIGGER checklist_items_sync_trip_id_trigger
  BEFORE INSERT OR UPDATE OF checklist_id ON public.checklist_items
  FOR EACH ROW
  EXECUTE PROCEDURE public.checklist_items_sync_trip_id();

CREATE OR REPLACE FUNCTION public.trip_checklists_bump_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trip_checklists_set_updated_at ON public.trip_checklists;
CREATE TRIGGER trip_checklists_set_updated_at
  BEFORE UPDATE ON public.trip_checklists
  FOR EACH ROW
  EXECUTE PROCEDURE public.trip_checklists_bump_updated_at();

CREATE OR REPLACE FUNCTION public.checklist_items_bump_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS checklist_items_set_updated_at ON public.checklist_items;
CREATE TRIGGER checklist_items_set_updated_at
  BEFORE UPDATE ON public.checklist_items
  FOR EACH ROW
  EXECUTE PROCEDURE public.checklist_items_bump_updated_at();

ALTER TABLE public.trip_checklists ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.checklist_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS trip_checklists_select_viewers ON public.trip_checklists;
CREATE POLICY trip_checklists_select_viewers
  ON public.trip_checklists
  FOR SELECT
  TO authenticated
  USING (public.can_view_trip(trip_id));

DROP POLICY IF EXISTS trip_checklists_insert_editors ON public.trip_checklists;
CREATE POLICY trip_checklists_insert_editors
  ON public.trip_checklists
  FOR INSERT
  TO authenticated
  WITH CHECK (
    public.can_edit_trip(trip_id)
    AND user_id = (SELECT auth.uid())
  );

DROP POLICY IF EXISTS trip_checklists_update_editors ON public.trip_checklists;
CREATE POLICY trip_checklists_update_editors
  ON public.trip_checklists
  FOR UPDATE
  TO authenticated
  USING (public.can_edit_trip(trip_id))
  WITH CHECK (public.can_edit_trip(trip_id));

DROP POLICY IF EXISTS trip_checklists_delete_editors ON public.trip_checklists;
CREATE POLICY trip_checklists_delete_editors
  ON public.trip_checklists
  FOR DELETE
  TO authenticated
  USING (public.can_edit_trip(trip_id));

DROP POLICY IF EXISTS checklist_items_select_viewers ON public.checklist_items;
CREATE POLICY checklist_items_select_viewers
  ON public.checklist_items
  FOR SELECT
  TO authenticated
  USING (public.can_view_trip(trip_id));

DROP POLICY IF EXISTS checklist_items_insert_editors ON public.checklist_items;
CREATE POLICY checklist_items_insert_editors
  ON public.checklist_items
  FOR INSERT
  TO authenticated
  WITH CHECK (
    public.can_edit_trip(trip_id)
    AND user_id = (SELECT auth.uid())
  );

DROP POLICY IF EXISTS checklist_items_update_editors ON public.checklist_items;
CREATE POLICY checklist_items_update_editors
  ON public.checklist_items
  FOR UPDATE
  TO authenticated
  USING (public.can_edit_trip(trip_id))
  WITH CHECK (public.can_edit_trip(trip_id));

DROP POLICY IF EXISTS checklist_items_delete_editors ON public.checklist_items;
CREATE POLICY checklist_items_delete_editors
  ON public.checklist_items
  FOR DELETE
  TO authenticated
  USING (public.can_edit_trip(trip_id));
