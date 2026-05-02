-- Trip expenses (V2a budget). RLS: view = can_view_trip, mutate = can_edit_trip.
-- Also allow editors to update `trips` (budget fields) when setting a trip budget.

CREATE TABLE IF NOT EXISTS public.trip_expenses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  trip_id uuid NOT NULL REFERENCES public.trips (id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  title text NOT NULL DEFAULT '',
  amount numeric(14, 2) NOT NULL CHECK (amount >= 0),
  currency text NOT NULL DEFAULT 'USD',
  category text,
  spent_at date,
  notes text,
  payer_user_id uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- Legacy DBs may have trip_expenses without newer columns (e.g. spent_at, user_id).
ALTER TABLE public.trip_expenses ADD COLUMN IF NOT EXISTS trip_id uuid REFERENCES public.trips (id) ON DELETE CASCADE;
ALTER TABLE public.trip_expenses ADD COLUMN IF NOT EXISTS user_id uuid REFERENCES auth.users (id) ON DELETE CASCADE;
ALTER TABLE public.trip_expenses ADD COLUMN IF NOT EXISTS title text NOT NULL DEFAULT '';
ALTER TABLE public.trip_expenses ADD COLUMN IF NOT EXISTS amount numeric(14, 2) NOT NULL DEFAULT 0;
ALTER TABLE public.trip_expenses ADD COLUMN IF NOT EXISTS currency text NOT NULL DEFAULT 'USD';
ALTER TABLE public.trip_expenses ADD COLUMN IF NOT EXISTS category text;
ALTER TABLE public.trip_expenses ADD COLUMN IF NOT EXISTS spent_at date;
ALTER TABLE public.trip_expenses ADD COLUMN IF NOT EXISTS notes text;
ALTER TABLE public.trip_expenses ADD COLUMN IF NOT EXISTS payer_user_id uuid REFERENCES auth.users (id) ON DELETE SET NULL;
ALTER TABLE public.trip_expenses ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE public.trip_expenses ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

CREATE INDEX IF NOT EXISTS trip_expenses_trip_spent_idx ON public.trip_expenses (trip_id, spent_at DESC NULLS LAST);
CREATE INDEX IF NOT EXISTS trip_expenses_trip_created_idx ON public.trip_expenses (trip_id, created_at DESC);

COMMENT ON TABLE public.trip_expenses IS 'Per-trip expense line items; currency per row; summary uses trip.budget_currency in app when matching.';

CREATE OR REPLACE FUNCTION public.trip_expenses_bump_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trip_expenses_set_updated_at ON public.trip_expenses;
CREATE TRIGGER trip_expenses_set_updated_at
  BEFORE UPDATE ON public.trip_expenses
  FOR EACH ROW
  EXECUTE PROCEDURE public.trip_expenses_bump_updated_at();

ALTER TABLE public.trip_expenses ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS trip_expenses_select_viewers ON public.trip_expenses;
CREATE POLICY trip_expenses_select_viewers
  ON public.trip_expenses
  FOR SELECT
  TO authenticated
  USING (public.can_view_trip(trip_id));

DROP POLICY IF EXISTS trip_expenses_insert_editors ON public.trip_expenses;
CREATE POLICY trip_expenses_insert_editors
  ON public.trip_expenses
  FOR INSERT
  TO authenticated
  WITH CHECK (
    public.can_edit_trip(trip_id)
    AND user_id = (SELECT auth.uid())
  );

DROP POLICY IF EXISTS trip_expenses_update_editors ON public.trip_expenses;
CREATE POLICY trip_expenses_update_editors
  ON public.trip_expenses
  FOR UPDATE
  TO authenticated
  USING (public.can_edit_trip(trip_id))
  WITH CHECK (public.can_edit_trip(trip_id));

DROP POLICY IF EXISTS trip_expenses_delete_editors ON public.trip_expenses;
CREATE POLICY trip_expenses_delete_editors
  ON public.trip_expenses
  FOR DELETE
  TO authenticated
  USING (public.can_edit_trip(trip_id));

-- Editors (and owners) may update trip rows — used for total_budget / budget_currency and aligns with collaborative editing.
DROP POLICY IF EXISTS trips_update_can_edit ON public.trips;
CREATE POLICY trips_update_can_edit
  ON public.trips
  FOR UPDATE
  TO authenticated
  USING (public.can_edit_trip(id))
  WITH CHECK (public.can_edit_trip(id));
