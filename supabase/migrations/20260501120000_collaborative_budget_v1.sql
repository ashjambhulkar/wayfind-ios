-- Collaborative Budget v1 — schema, triggers, RLS, realtime.
-- See plan: collaborative_budget_implementation_e445d1c8.plan.md
--
-- Adds:
--   * trip_collaborators.can_see_expenses (default false; backfill true for legacy rows)
--   * trip_bookings.amount + currency
--   * trip_expenses.is_auto_synced (booking-driven sync guard)
--   * expense_splits.trip_id (denormalised for Realtime trip_id=eq filters)
--   * expense_settlements table + RLS
--   * Triggers: tg_sync_booking_expense / tg_unmark_auto_synced_on_user_edit /
--              tg_log_expense_changes / tg_log_settlement_changes /
--              tg_log_budget_changes / tg_log_trip_total_budget_changes /
--              tg_expense_splits_set_trip_id
--   * trip_activity_log CHECK extension (expense_added / _updated / _deleted /
--     expense_settled / budget_updated)
--   * Realtime publication adds (trip_expenses, expense_splits, trip_budgets,
--     expense_settlements)
-- Spent-amount rollup is intentionally NOT added — clients compute spent from
-- trip_expenses (single source of truth).


-- ─── 0. Per-user payment handles for settle-up deep links ──────────────────
-- Optional handles a user can fill in from Edit Profile. Used by the
-- settlement sheet to assemble venmo:// / https://paypal.me URLs. Storing
-- only the username (no scheme prefix) keeps the column flexible if Venmo
-- changes its URL shape.
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS venmo_username text;

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS paypal_username text;


-- ─── 1. Per-surface access flag for expenses ─────────────────────────────────
ALTER TABLE public.trip_collaborators
  ADD COLUMN IF NOT EXISTS can_see_expenses boolean NOT NULL DEFAULT false;

-- Backfill existing rows: prior to this migration the iOS client treated
-- every collaborator as having expense access (model defaulted to true).
-- Setting these to true preserves access on deploy; new collaborators added
-- after this migration default to false until the inviter explicitly grants.
UPDATE public.trip_collaborators
SET can_see_expenses = true
WHERE can_see_expenses = false;


-- ─── 2. Booking monetary fields (drives auto-sync) ───────────────────────────
ALTER TABLE public.trip_bookings
  ADD COLUMN IF NOT EXISTS amount numeric;

ALTER TABLE public.trip_bookings
  ADD COLUMN IF NOT EXISTS currency text NOT NULL DEFAULT 'USD';


-- ─── 3. trips.total_budget: allow NULL for "not set yet" ─────────────────────
DO $alter$
BEGIN
  -- Drop default if it exists, then make column nullable (was set to default 0 +
  -- not null in early bootstrap; "0" was indistinguishable from "no budget").
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'trips'
      AND column_name = 'total_budget'
  ) THEN
    EXECUTE 'ALTER TABLE public.trips ALTER COLUMN total_budget DROP DEFAULT';
    EXECUTE 'ALTER TABLE public.trips ALTER COLUMN total_budget DROP NOT NULL';
    -- A literal 0 means "not set" once nullability lands; convert in place so
    -- the UI distinguishes "owner has not set a budget" from "$0".
    EXECUTE 'UPDATE public.trips SET total_budget = NULL WHERE total_budget = 0';
  END IF;
END
$alter$;


-- ─── 4. trip_expenses: is_auto_synced flag for booking-driven idempotency ────
ALTER TABLE public.trip_expenses
  ADD COLUMN IF NOT EXISTS is_auto_synced boolean NOT NULL DEFAULT false;

CREATE INDEX IF NOT EXISTS trip_expenses_booking_id_idx
  ON public.trip_expenses (booking_id)
  WHERE booking_id IS NOT NULL;


-- ─── 5. expense_splits.trip_id denormalised for Realtime ─────────────────────
ALTER TABLE public.expense_splits
  ADD COLUMN IF NOT EXISTS trip_id uuid REFERENCES public.trips(id) ON DELETE CASCADE;

UPDATE public.expense_splits es
SET trip_id = te.trip_id
FROM public.trip_expenses te
WHERE es.trip_id IS NULL
  AND te.id = es.expense_id;

CREATE INDEX IF NOT EXISTS expense_splits_trip_id_idx
  ON public.expense_splits (trip_id);

-- Editor-level RLS using the denormalised trip_id. Existing "expense creator"
-- policies are left in place — PostgreSQL ORs multiple permissive policies for
-- the same operation, so the creator path keeps working and any editor on the
-- trip can also reconcile splits.
DROP POLICY IF EXISTS expense_splits_update_editors ON public.expense_splits;
CREATE POLICY expense_splits_update_editors
  ON public.expense_splits
  FOR UPDATE
  TO authenticated
  USING (trip_id IS NOT NULL AND public.can_edit_trip(trip_id))
  WITH CHECK (trip_id IS NOT NULL AND public.can_edit_trip(trip_id));

DROP POLICY IF EXISTS expense_splits_delete_editors ON public.expense_splits;
CREATE POLICY expense_splits_delete_editors
  ON public.expense_splits
  FOR DELETE
  TO authenticated
  USING (trip_id IS NOT NULL AND public.can_edit_trip(trip_id));

CREATE OR REPLACE FUNCTION public.tg_expense_splits_set_trip_id()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $tg$
BEGIN
  IF NEW.trip_id IS NULL THEN
    SELECT te.trip_id
    INTO NEW.trip_id
    FROM public.trip_expenses te
    WHERE te.id = NEW.expense_id;
  END IF;
  RETURN NEW;
END;
$tg$;

DROP TRIGGER IF EXISTS expense_splits_set_trip_id ON public.expense_splits;
CREATE TRIGGER expense_splits_set_trip_id
  BEFORE INSERT OR UPDATE OF expense_id ON public.expense_splits
  FOR EACH ROW
  EXECUTE PROCEDURE public.tg_expense_splits_set_trip_id();


-- ─── 6. expense_settlements table + RLS ──────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.expense_settlements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  trip_id uuid NOT NULL REFERENCES public.trips(id) ON DELETE CASCADE,
  from_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  to_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  amount numeric NOT NULL CHECK (amount > 0),
  currency text NOT NULL DEFAULT 'USD',
  is_settled boolean NOT NULL DEFAULT false,
  settled_at timestamptz,
  -- 'cash' | 'venmo' | 'paypal' | 'other' (Apple Pay Cash has no public P2P URL,
  -- and a free-form 'other' bucket keeps the column from blocking new methods).
  settled_via text CHECK (settled_via IS NULL OR settled_via IN ('cash', 'venmo', 'paypal', 'other')),
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT expense_settlements_distinct_users CHECK (from_user_id <> to_user_id)
);

CREATE INDEX IF NOT EXISTS expense_settlements_trip_id_idx
  ON public.expense_settlements (trip_id);

CREATE INDEX IF NOT EXISTS expense_settlements_from_user_idx
  ON public.expense_settlements (from_user_id);

CREATE INDEX IF NOT EXISTS expense_settlements_to_user_idx
  ON public.expense_settlements (to_user_id);

CREATE OR REPLACE FUNCTION public.expense_settlements_bump_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS expense_settlements_set_updated_at ON public.expense_settlements;
CREATE TRIGGER expense_settlements_set_updated_at
  BEFORE UPDATE ON public.expense_settlements
  FOR EACH ROW
  EXECUTE PROCEDURE public.expense_settlements_bump_updated_at();

ALTER TABLE public.expense_settlements ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS expense_settlements_select_members ON public.expense_settlements;
CREATE POLICY expense_settlements_select_members
  ON public.expense_settlements
  FOR SELECT
  TO authenticated
  USING (public.can_view_trip(trip_id));

-- Insert: must be a trip member, AND must be a party to the settlement.
DROP POLICY IF EXISTS expense_settlements_insert_party ON public.expense_settlements;
CREATE POLICY expense_settlements_insert_party
  ON public.expense_settlements
  FOR INSERT
  TO authenticated
  WITH CHECK (
    public.can_view_trip(trip_id)
    AND (
      from_user_id = (SELECT auth.uid())
      OR to_user_id = (SELECT auth.uid())
    )
  );

-- Update: either party may mark the settlement settled. The recipient is the
-- one who actually saw the money, so they have the strongest claim on the
-- "settled" toggle, but in practice both parties touch this row from their
-- own device.
DROP POLICY IF EXISTS expense_settlements_update_party ON public.expense_settlements;
CREATE POLICY expense_settlements_update_party
  ON public.expense_settlements
  FOR UPDATE
  TO authenticated
  USING (
    public.can_view_trip(trip_id)
    AND (
      from_user_id = (SELECT auth.uid())
      OR to_user_id = (SELECT auth.uid())
    )
  )
  WITH CHECK (
    public.can_view_trip(trip_id)
    AND (
      from_user_id = (SELECT auth.uid())
      OR to_user_id = (SELECT auth.uid())
    )
  );

-- No DELETE policy: settlements are append-only history. To "undo" a settle,
-- create a reverse settlement.


-- ─── 7. Booking → Expense auto-sync ──────────────────────────────────────────
-- Idempotent: only updates rows it originally created (is_auto_synced = true).
-- Once a user manually edits the auto-created expense, is_auto_synced flips to
-- false (see trigger 8) and subsequent booking edits leave the expense alone.
--
-- Map booking.kind → expense.category:
--   flight                              → flight
--   lodging                             → lodging
--   car                                 → car
--   restaurant                          → food
--   train | bus | ferry | cruise        → transport
--   concert | theater | tour            → activities
--   anything else                       → other
CREATE OR REPLACE FUNCTION public.tg_sync_booking_expense()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $sync$
DECLARE
  v_category text;
  v_currency text;
  v_title text;
  v_existing_id uuid;
  v_existing_auto boolean;
  v_actor uuid;
BEGIN
  -- Recursion guard: if any of our other triggers fire this one again
  -- (e.g. trip_expenses UPDATE → activity log → ...), bail out.
  IF pg_trigger_depth() > 1 THEN
    RETURN NEW;
  END IF;

  -- Ignore bookings without a positive amount; never auto-delete an existing
  -- expense if the user clears the field — they may want to keep tracking it.
  IF NEW.amount IS NULL OR NEW.amount <= 0 THEN
    RETURN NEW;
  END IF;

  v_category := CASE NEW.kind
    WHEN 'flight' THEN 'flight'
    WHEN 'lodging' THEN 'lodging'
    WHEN 'car' THEN 'car'
    WHEN 'restaurant' THEN 'food'
    WHEN 'train' THEN 'transport'
    WHEN 'bus' THEN 'transport'
    WHEN 'ferry' THEN 'transport'
    WHEN 'cruise' THEN 'transport'
    WHEN 'transport' THEN 'transport'
    WHEN 'concert' THEN 'activities'
    WHEN 'theater' THEN 'activities'
    WHEN 'tour' THEN 'activities'
    WHEN 'activity' THEN 'activities'
    WHEN 'activities' THEN 'activities'
    ELSE 'other'
  END;

  v_currency := COALESCE(NULLIF(trim(NEW.currency), ''), 'USD');
  v_title := COALESCE(NULLIF(trim(NEW.title), ''), 'Booking');
  v_actor := COALESCE(
    NEW.user_id,
    (SELECT t.user_id FROM public.trips t WHERE t.id = NEW.trip_id LIMIT 1)
  );

  IF v_actor IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT te.id, te.is_auto_synced
  INTO v_existing_id, v_existing_auto
  FROM public.trip_expenses te
  WHERE te.booking_id = NEW.id
  LIMIT 1;

  IF v_existing_id IS NULL THEN
    INSERT INTO public.trip_expenses (
      trip_id,
      user_id,
      booking_id,
      title,
      amount,
      currency,
      category,
      split_type,
      payer_user_id,
      expense_date,
      is_auto_synced
    )
    VALUES (
      NEW.trip_id,
      v_actor,
      NEW.id,
      v_title,
      NEW.amount,
      v_currency,
      v_category,
      'full',
      v_actor,
      COALESCE(NEW.starts_at::date, CURRENT_DATE),
      true
    );
  ELSIF v_existing_auto THEN
    -- Refresh the auto-row in place. We deliberately don't bump payer or split
    -- here — the row was created by us, but a viewing collaborator may have
    -- left those alone; the only fields driven by the booking are amount /
    -- currency / title / category.
    UPDATE public.trip_expenses
    SET title = v_title,
        amount = NEW.amount,
        currency = v_currency,
        category = v_category
    WHERE id = v_existing_id
      AND is_auto_synced = true;
  END IF;

  RETURN NEW;
END;
$sync$;

DROP TRIGGER IF EXISTS trip_bookings_sync_expense ON public.trip_bookings;
CREATE TRIGGER trip_bookings_sync_expense
  AFTER INSERT OR UPDATE OF amount, currency, title, kind, starts_at ON public.trip_bookings
  FOR EACH ROW
  EXECUTE PROCEDURE public.tg_sync_booking_expense();


-- ─── 8. Mark expense rows as user-owned the moment a user edits them ─────────
-- Runs only outside trigger context (depth = 1 at fire time = depth = 0 caller),
-- so the auto-sync trigger above won't trip this one.
CREATE OR REPLACE FUNCTION public.tg_unmark_auto_synced_on_user_edit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF pg_trigger_depth() > 1 THEN
    RETURN NEW;
  END IF;

  IF NEW.is_auto_synced
     AND (
       OLD.title IS DISTINCT FROM NEW.title
       OR OLD.amount IS DISTINCT FROM NEW.amount
       OR OLD.currency IS DISTINCT FROM NEW.currency
       OR OLD.category IS DISTINCT FROM NEW.category
       OR OLD.notes IS DISTINCT FROM NEW.notes
       OR OLD.payer_user_id IS DISTINCT FROM NEW.payer_user_id
       OR OLD.split_type IS DISTINCT FROM NEW.split_type
       OR OLD.expense_date IS DISTINCT FROM NEW.expense_date
     )
  THEN
    NEW.is_auto_synced := false;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trip_expenses_unmark_auto_synced ON public.trip_expenses;
CREATE TRIGGER trip_expenses_unmark_auto_synced
  BEFORE UPDATE ON public.trip_expenses
  FOR EACH ROW
  EXECUTE PROCEDURE public.tg_unmark_auto_synced_on_user_edit();


-- ─── 9. Activity log: extend CHECK with budget actions ──────────────────────
ALTER TABLE public.trip_activity_log
  DROP CONSTRAINT IF EXISTS trip_activity_log_action_check;

ALTER TABLE public.trip_activity_log
  ADD CONSTRAINT trip_activity_log_action_check CHECK (
    action IN (
      'activity_added',
      'activity_updated',
      'activity_deleted',
      'booking_added',
      'booking_updated',
      'booking_deleted',
      'note_added',
      'note_updated',
      'checklist_added',
      'checklist_item_toggled',
      'day_reordered',
      'collaborator_joined',
      'collaborator_left',
      'collaborator_role_changed',
      'trip_updated',
      'pending_invite_declined',
      'expense_added',
      'expense_updated',
      'expense_deleted',
      'expense_settled',
      'budget_updated'
    )
  );


-- ─── 10. Activity log triggers for expenses ─────────────────────────────────
CREATE OR REPLACE FUNCTION public.tg_log_expense_changes()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $log$
DECLARE
  v_actor uuid;
BEGIN
  IF tg_op = 'INSERT' THEN
    v_actor := COALESCE(
      NEW.user_id,
      NEW.payer_user_id,
      (SELECT t.user_id FROM public.trips t WHERE t.id = NEW.trip_id LIMIT 1)
    );
    IF v_actor IS NULL THEN
      RETURN NEW;
    END IF;
    INSERT INTO public.trip_activity_log (trip_id, user_id, action, entity_type, entity_id, entity_name, metadata)
    VALUES (
      NEW.trip_id,
      v_actor,
      'expense_added',
      'trip_expense',
      NEW.id,
      COALESCE(NULLIF(trim(NEW.title), ''), 'Expense'),
      jsonb_build_object(
        'amount', NEW.amount::text,
        'currency', NEW.currency,
        'category', NEW.category,
        'auto', NEW.is_auto_synced
      )
    );
    RETURN NEW;

  ELSIF tg_op = 'UPDATE' THEN
    -- Meaningful-change filter: skip log when only updated_at differs, so a
    -- typo correction or split rebalance doesn't spam the activity feed.
    IF OLD.title IS NOT DISTINCT FROM NEW.title
       AND OLD.amount IS NOT DISTINCT FROM NEW.amount
       AND OLD.currency IS NOT DISTINCT FROM NEW.currency
       AND OLD.category IS NOT DISTINCT FROM NEW.category
       AND OLD.payer_user_id IS NOT DISTINCT FROM NEW.payer_user_id
       AND OLD.split_type IS NOT DISTINCT FROM NEW.split_type
       AND OLD.notes IS NOT DISTINCT FROM NEW.notes
       AND OLD.expense_date IS NOT DISTINCT FROM NEW.expense_date
    THEN
      RETURN NEW;
    END IF;

    v_actor := COALESCE(
      (SELECT auth.uid()),
      NEW.user_id,
      NEW.payer_user_id,
      (SELECT t.user_id FROM public.trips t WHERE t.id = NEW.trip_id LIMIT 1)
    );
    IF v_actor IS NULL THEN
      RETURN NEW;
    END IF;
    INSERT INTO public.trip_activity_log (trip_id, user_id, action, entity_type, entity_id, entity_name, metadata)
    VALUES (
      NEW.trip_id,
      v_actor,
      'expense_updated',
      'trip_expense',
      NEW.id,
      COALESCE(NULLIF(trim(NEW.title), ''), 'Expense'),
      jsonb_build_object(
        'amount', NEW.amount::text,
        'currency', NEW.currency,
        'category', NEW.category
      )
    );
    RETURN NEW;

  ELSIF tg_op = 'DELETE' THEN
    -- Skip orphan logging when the parent trip itself is being deleted.
    IF NOT EXISTS (SELECT 1 FROM public.trips t WHERE t.id = OLD.trip_id) THEN
      RETURN OLD;
    END IF;

    v_actor := COALESCE(
      (SELECT auth.uid()),
      OLD.user_id,
      OLD.payer_user_id,
      (SELECT t.user_id FROM public.trips t WHERE t.id = OLD.trip_id LIMIT 1)
    );
    IF v_actor IS NULL THEN
      RETURN OLD;
    END IF;
    INSERT INTO public.trip_activity_log (trip_id, user_id, action, entity_type, entity_id, entity_name, metadata)
    VALUES (
      OLD.trip_id,
      v_actor,
      'expense_deleted',
      'trip_expense',
      OLD.id,
      COALESCE(NULLIF(trim(OLD.title), ''), 'Expense'),
      jsonb_build_object(
        'amount', OLD.amount::text,
        'currency', OLD.currency,
        'category', OLD.category
      )
    );
    RETURN OLD;
  END IF;
  RETURN NULL;
END;
$log$;

DROP TRIGGER IF EXISTS trip_expenses_log_collab ON public.trip_expenses;
CREATE TRIGGER trip_expenses_log_collab
  AFTER INSERT OR UPDATE OR DELETE ON public.trip_expenses
  FOR EACH ROW
  EXECUTE PROCEDURE public.tg_log_expense_changes();


-- ─── 11. Activity log trigger for settlement transitions ────────────────────
CREATE OR REPLACE FUNCTION public.tg_log_settlement_changes()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $log$
DECLARE
  v_actor uuid;
BEGIN
  -- Only log the settle event itself; INSERTs that arrive already-settled also
  -- count, but a row created in 'pending' state should stay quiet until the
  -- recipient flips it.
  IF tg_op = 'INSERT' THEN
    IF NOT NEW.is_settled THEN
      RETURN NEW;
    END IF;
  ELSIF tg_op = 'UPDATE' THEN
    IF OLD.is_settled = NEW.is_settled THEN
      RETURN NEW;
    END IF;
    IF NOT NEW.is_settled THEN
      -- "Un-settling" should not happen via app, but if it does, don't log.
      RETURN NEW;
    END IF;
  ELSE
    RETURN NULL;
  END IF;

  v_actor := COALESCE((SELECT auth.uid()), NEW.from_user_id);
  IF v_actor IS NULL THEN
    RETURN NEW;
  END IF;

  INSERT INTO public.trip_activity_log (trip_id, user_id, action, entity_type, entity_id, metadata)
  VALUES (
    NEW.trip_id,
    v_actor,
    'expense_settled',
    'expense_settlement',
    NEW.id,
    jsonb_build_object(
      'from_user_id', NEW.from_user_id,
      'to_user_id', NEW.to_user_id,
      'amount', NEW.amount::text,
      'currency', NEW.currency,
      'method', COALESCE(NEW.settled_via, 'other')
    )
  );
  RETURN NEW;
END;
$log$;

DROP TRIGGER IF EXISTS expense_settlements_log_collab ON public.expense_settlements;
CREATE TRIGGER expense_settlements_log_collab
  AFTER INSERT OR UPDATE ON public.expense_settlements
  FOR EACH ROW
  EXECUTE PROCEDURE public.tg_log_settlement_changes();


-- ─── 12. Activity log trigger for per-category budget changes ───────────────
CREATE OR REPLACE FUNCTION public.tg_log_budget_changes()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $log$
DECLARE
  v_actor uuid;
BEGIN
  IF tg_op = 'UPDATE' AND OLD.planned_amount IS NOT DISTINCT FROM NEW.planned_amount
     AND OLD.currency IS NOT DISTINCT FROM NEW.currency
  THEN
    RETURN NEW;
  END IF;

  v_actor := COALESCE(
    (SELECT auth.uid()),
    CASE WHEN tg_op = 'DELETE' THEN OLD.user_id ELSE NEW.user_id END,
    (SELECT t.user_id FROM public.trips t
      WHERE t.id = COALESCE(NEW.trip_id, OLD.trip_id) LIMIT 1)
  );
  IF v_actor IS NULL THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  INSERT INTO public.trip_activity_log (trip_id, user_id, action, entity_type, entity_id, metadata)
  VALUES (
    COALESCE(NEW.trip_id, OLD.trip_id),
    v_actor,
    'budget_updated',
    'trip_budget',
    COALESCE(NEW.id, OLD.id),
    jsonb_build_object(
      'category', COALESCE(NEW.category, OLD.category),
      'planned_amount', COALESCE(NEW.planned_amount, 0)::text,
      'currency', COALESCE(NEW.currency, OLD.currency)
    )
  );
  RETURN COALESCE(NEW, OLD);
END;
$log$;

DROP TRIGGER IF EXISTS trip_budgets_log_collab ON public.trip_budgets;
CREATE TRIGGER trip_budgets_log_collab
  AFTER INSERT OR UPDATE OR DELETE ON public.trip_budgets
  FOR EACH ROW
  EXECUTE PROCEDURE public.tg_log_budget_changes();


-- ─── 13. trips.total_budget changes also surface as budget_updated ──────────
CREATE OR REPLACE FUNCTION public.tg_log_trip_total_budget_changes()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $log$
DECLARE
  v_actor uuid;
BEGIN
  IF tg_op <> 'UPDATE' THEN
    RETURN NEW;
  END IF;

  IF OLD.total_budget IS NOT DISTINCT FROM NEW.total_budget
     AND OLD.budget_currency IS NOT DISTINCT FROM NEW.budget_currency
  THEN
    RETURN NEW;
  END IF;

  v_actor := COALESCE((SELECT auth.uid()), NEW.user_id);
  IF v_actor IS NULL THEN
    RETURN NEW;
  END IF;

  INSERT INTO public.trip_activity_log (trip_id, user_id, action, entity_type, entity_id, metadata)
  VALUES (
    NEW.id,
    v_actor,
    'budget_updated',
    'trip',
    NEW.id,
    jsonb_build_object(
      'scope', 'trip_total',
      'total_budget', COALESCE(NEW.total_budget, 0)::text,
      'currency', NEW.budget_currency
    )
  );
  RETURN NEW;
END;
$log$;

DROP TRIGGER IF EXISTS trips_log_total_budget ON public.trips;
CREATE TRIGGER trips_log_total_budget
  AFTER UPDATE OF total_budget, budget_currency ON public.trips
  FOR EACH ROW
  EXECUTE PROCEDURE public.tg_log_trip_total_budget_changes();


-- ─── 14. Realtime publication: budget tables ────────────────────────────────
DO $realtime$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'trip_expenses',
    'expense_splits',
    'trip_budgets',
    'expense_settlements'
  ]
  LOOP
    IF NOT EXISTS (
      SELECT 1
      FROM pg_publication_tables
      WHERE pubname = 'supabase_realtime'
        AND schemaname = 'public'
        AND tablename = t
    ) THEN
      EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', t);
    END IF;
  END LOOP;
END
$realtime$;

-- REPLICA IDENTITY FULL is required for DELETE Realtime payloads to carry the
-- trip_id (for client-side filter routing).
ALTER TABLE public.trip_expenses REPLICA IDENTITY FULL;
ALTER TABLE public.expense_splits REPLICA IDENTITY FULL;
ALTER TABLE public.trip_budgets REPLICA IDENTITY FULL;
ALTER TABLE public.expense_settlements REPLICA IDENTITY FULL;
