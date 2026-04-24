-- Fixed tabs: Packing, To-Do, Documents (seeded items), General (empty). Idempotent per trip.

ALTER TABLE public.trip_checklists
  ADD COLUMN IF NOT EXISTS template_key text NULL;

ALTER TABLE public.trip_checklists DROP CONSTRAINT IF EXISTS trip_checklists_template_key_check;
ALTER TABLE public.trip_checklists
  ADD CONSTRAINT trip_checklists_template_key_check
  CHECK (
    template_key IS NULL
    OR template_key IN ('packing', 'todo', 'documents', 'general')
  );

CREATE UNIQUE INDEX IF NOT EXISTS trip_checklists_trip_template_key_uidx
  ON public.trip_checklists (trip_id, template_key)
  WHERE template_key IS NOT NULL;

COMMENT ON COLUMN public.trip_checklists.template_key IS 'Built-in checklist tab: packing | todo | documents | general. NULL = legacy user-created list.';

CREATE OR REPLACE FUNCTION public.ensure_trip_checklist_templates(p_trip_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  v_owner uuid;
  v_cid uuid;
BEGIN
  IF NOT public.can_view_trip(p_trip_id) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT t.user_id INTO v_owner FROM public.trips t WHERE t.id = p_trip_id;
  IF v_owner IS NULL THEN
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.trip_checklists c WHERE c.trip_id = p_trip_id AND c.template_key = 'packing'
  ) THEN
    INSERT INTO public.trip_checklists (trip_id, user_id, title, sort_order, template_key)
    VALUES (p_trip_id, v_owner, 'Packing', 0, 'packing')
    RETURNING id INTO v_cid;

    INSERT INTO public.checklist_items (checklist_id, trip_id, user_id, title, sort_order, is_done)
    VALUES
      (v_cid, p_trip_id, v_owner, 'Passport & visa', 0, false),
      (v_cid, p_trip_id, v_owner, 'Travel adapter (EU plug)', 1, false),
      (v_cid, p_trip_id, v_owner, 'Rough itinerary sketch', 2, false),
      (v_cid, p_trip_id, v_owner, 'Comfortable walking shoes', 3, false),
      (v_cid, p_trip_id, v_owner, 'Camera & chargers', 4, false),
      (v_cid, p_trip_id, v_owner, 'Light jacket (evenings)', 5, false);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.trip_checklists c WHERE c.trip_id = p_trip_id AND c.template_key = 'todo'
  ) THEN
    INSERT INTO public.trip_checklists (trip_id, user_id, title, sort_order, template_key)
    VALUES (p_trip_id, v_owner, 'To-Do', 1, 'todo')
    RETURNING id INTO v_cid;

    INSERT INTO public.checklist_items (checklist_id, trip_id, user_id, title, sort_order, is_done)
    VALUES
      (v_cid, p_trip_id, v_owner, 'Book airport transfer', 0, false),
      (v_cid, p_trip_id, v_owner, 'Confirm hotel check-in time', 1, false),
      (v_cid, p_trip_id, v_owner, 'Download offline maps', 2, false),
      (v_cid, p_trip_id, v_owner, 'Notify bank of travel', 3, false);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.trip_checklists c WHERE c.trip_id = p_trip_id AND c.template_key = 'documents'
  ) THEN
    INSERT INTO public.trip_checklists (trip_id, user_id, title, sort_order, template_key)
    VALUES (p_trip_id, v_owner, 'Documents', 2, 'documents')
    RETURNING id INTO v_cid;

    INSERT INTO public.checklist_items (checklist_id, trip_id, user_id, title, sort_order, is_done)
    VALUES
      (v_cid, p_trip_id, v_owner, 'Passport copy (digital)', 0, false),
      (v_cid, p_trip_id, v_owner, 'Travel insurance details', 1, false),
      (v_cid, p_trip_id, v_owner, 'Flight or train confirmations', 2, false),
      (v_cid, p_trip_id, v_owner, 'Hotel booking confirmation', 3, false);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.trip_checklists c WHERE c.trip_id = p_trip_id AND c.template_key = 'general'
  ) THEN
    INSERT INTO public.trip_checklists (trip_id, user_id, title, sort_order, template_key)
    VALUES (p_trip_id, v_owner, 'General', 3, 'general');
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.ensure_trip_checklist_templates(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.ensure_trip_checklist_templates(uuid) TO authenticated;
