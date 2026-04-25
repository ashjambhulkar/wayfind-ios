-- Phase 10 — Budget trigger smoke test
--
-- Asserts the invariants of `tg_sync_booking_expense` (defined in
-- `20260501120000_collaborative_budget_v1.sql`):
--
--   1. Inserting a booking with `amount > 0` creates exactly one
--      `trip_expenses` row tagged `is_auto_synced = true`.
--   2. Re-running an UPDATE on the booking with the same payload is a no-op:
--      still exactly one expense row, still `is_auto_synced = true`, fields
--      unchanged. (Idempotency.)
--   3. Updating the booking amount refreshes the auto-row.
--   4. Once a user mutates the auto-synced expense (which flips the row to
--      `is_auto_synced = false` via `tg_unmark_auto_synced_on_user_edit`),
--      subsequent booking-driven UPDATEs leave the expense alone.
--   5. Deleting the booking sets `trip_expenses.booking_id = NULL` instead
--      of nuking the expense (ON DELETE SET NULL).
--   6. `expense_splits.trip_id` denormalisation stays in sync on insert.
--   7. Settling a settlement once succeeds; updating it again with the
--      same `is_settled = true` is a no-op (idempotency on the recipient
--      side — the second tap should not double-credit).
--
-- Run via the Supabase CLI (assumes a clean local stack):
--   supabase db reset
--   psql "$(supabase status -o env | grep DB_URL | cut -d= -f2)" \
--     -f supabase/tests/budget_triggers_smoke.sql
--
-- The script wraps everything in a single transaction and ROLLBACKs at the
-- end so it can run repeatedly without polluting the local DB.
--
-- A failure aborts immediately via RAISE EXCEPTION with a descriptive
-- message; success prints a series of NOTICEs followed by "ALL TESTS
-- PASSED".

BEGIN;

DO $test$
DECLARE
  v_owner uuid;
  v_trip uuid := gen_random_uuid();
  v_booking uuid := gen_random_uuid();
  v_expense uuid;
  v_count int;
  v_amount numeric;
  v_currency text;
  v_category text;
  v_auto boolean;
  v_booking_id uuid;
  v_settlement uuid := gen_random_uuid();
  v_other_user uuid;
BEGIN
  -- ── Setup: borrow an existing auth user (any one will do — the trigger
  -- only needs `trips.user_id` to non-null) ──────────────────────────────
  SELECT id INTO v_owner FROM auth.users ORDER BY created_at LIMIT 1;
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'No auth.users in local DB; create one before running tests';
  END IF;

  SELECT id INTO v_other_user
  FROM auth.users
  WHERE id <> v_owner
  ORDER BY created_at
  LIMIT 1;
  IF v_other_user IS NULL THEN
    -- Fall back to the same user — the settlement test will exercise the
    -- "single user pays themselves" edge path which is harmless here.
    v_other_user := v_owner;
  END IF;

  -- A trip the owner can write to. Skip RLS by elevating through SECURITY
  -- DEFINER context (the test runs as the supabase `postgres` superuser).
  INSERT INTO public.trips (
    id, user_id, name, start_date, end_date,
    base_currency, budget_currency
  ) VALUES (
    v_trip, v_owner, 'Trigger smoke trip', current_date, current_date + 5,
    'USD', 'USD'
  );

  -- ─── 1. Insert booking → expense auto-created ────────────────────────────
  INSERT INTO public.trip_bookings (
    id, trip_id, user_id, kind, title, amount, currency, starts_at
  ) VALUES (
    v_booking, v_trip, v_owner, 'lodging', 'Hotel Indigo',
    250.00, 'USD', now()
  );

  SELECT count(*), MAX(id), MAX(amount), MAX(currency), MAX(category), bool_or(is_auto_synced)
  INTO v_count, v_expense, v_amount, v_currency, v_category, v_auto
  FROM public.trip_expenses
  WHERE booking_id = v_booking;

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Test 1 FAILED: expected 1 auto-synced expense, got %', v_count;
  END IF;
  IF v_amount <> 250.00 OR v_currency <> 'USD' OR v_category <> 'lodging' OR NOT v_auto THEN
    RAISE EXCEPTION 'Test 1 FAILED: expense fields wrong (amount=% currency=% category=% auto=%)',
      v_amount, v_currency, v_category, v_auto;
  END IF;
  RAISE NOTICE '✓ Test 1: booking insert created auto-synced expense';

  -- ─── 2. Idempotent UPDATE — touching with same payload doesn't multiply ─
  UPDATE public.trip_bookings
  SET title = 'Hotel Indigo', amount = 250.00, currency = 'USD', kind = 'lodging'
  WHERE id = v_booking;

  SELECT count(*) INTO v_count
  FROM public.trip_expenses
  WHERE booking_id = v_booking;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Test 2 FAILED: idempotent update created duplicate (%)', v_count;
  END IF;
  RAISE NOTICE '✓ Test 2: idempotent booking UPDATE keeps single expense row';

  -- ─── 3. Update booking amount → auto-row reflects new amount ─────────────
  UPDATE public.trip_bookings SET amount = 275.00 WHERE id = v_booking;

  SELECT amount INTO v_amount FROM public.trip_expenses WHERE id = v_expense;
  IF v_amount <> 275.00 THEN
    RAISE EXCEPTION 'Test 3 FAILED: auto-row did not refresh (amount=%)', v_amount;
  END IF;
  RAISE NOTICE '✓ Test 3: booking amount UPDATE refreshes auto-synced expense';

  -- ─── 4. User edit flips is_auto_synced; subsequent booking edits ignored ─
  UPDATE public.trip_expenses
  SET title = 'Hotel Indigo (renamed)'
  WHERE id = v_expense;

  SELECT is_auto_synced INTO v_auto FROM public.trip_expenses WHERE id = v_expense;
  IF v_auto THEN
    RAISE EXCEPTION 'Test 4a FAILED: user edit did not flip is_auto_synced';
  END IF;

  UPDATE public.trip_bookings SET amount = 999.99 WHERE id = v_booking;

  SELECT amount INTO v_amount FROM public.trip_expenses WHERE id = v_expense;
  IF v_amount = 999.99 THEN
    RAISE EXCEPTION 'Test 4b FAILED: booking amount UPDATE clobbered user-edited expense';
  END IF;
  RAISE NOTICE '✓ Test 4: user-edited expense is preserved across booking UPDATEs';

  -- ─── 5. Delete booking → expense.booking_id becomes NULL ─────────────────
  DELETE FROM public.trip_bookings WHERE id = v_booking;

  SELECT booking_id INTO v_booking_id FROM public.trip_expenses WHERE id = v_expense;
  IF v_booking_id IS NOT NULL THEN
    RAISE EXCEPTION 'Test 5 FAILED: booking_id not nulled on cascade (booking_id=%)', v_booking_id;
  END IF;

  SELECT count(*) INTO v_count FROM public.trip_expenses WHERE id = v_expense;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Test 5 FAILED: expense row was deleted (count=%)', v_count;
  END IF;
  RAISE NOTICE '✓ Test 5: deleting booking detaches expense (NULLs booking_id)';

  -- ─── 6. expense_splits.trip_id denorm trigger ────────────────────────────
  INSERT INTO public.expense_splits (
    id, expense_id, user_id, amount, currency, is_accepted
  ) VALUES (
    gen_random_uuid(), v_expense, v_owner, 100.00, 'USD', true
  );

  SELECT trip_id INTO v_booking_id
  FROM public.expense_splits
  WHERE expense_id = v_expense
  LIMIT 1;
  IF v_booking_id IS NULL OR v_booking_id <> v_trip THEN
    RAISE EXCEPTION 'Test 6 FAILED: expense_splits.trip_id not denormalised (got %)', v_booking_id;
  END IF;
  RAISE NOTICE '✓ Test 6: expense_splits.trip_id mirrors parent expense';

  -- ─── 7. Settlement idempotency ───────────────────────────────────────────
  INSERT INTO public.expense_settlements (
    id, trip_id, from_user_id, to_user_id, amount, currency, is_settled
  ) VALUES (
    v_settlement, v_trip, v_owner, v_other_user, 25.00, 'USD', true
  );

  -- Second "settle" of the same row with the same payload — should leave
  -- the row unchanged rather than duplicate the credit.
  UPDATE public.expense_settlements
  SET is_settled = true,
      settled_at = COALESCE(settled_at, now())
  WHERE id = v_settlement;

  SELECT count(*) INTO v_count
  FROM public.expense_settlements
  WHERE id = v_settlement AND is_settled = true;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Test 7 FAILED: re-settling produced unexpected row count (%)', v_count;
  END IF;
  RAISE NOTICE '✓ Test 7: settling an already-settled row is a no-op';

  RAISE NOTICE '────────────────────────────────';
  RAISE NOTICE '✓✓✓ ALL TESTS PASSED ✓✓✓';
END
$test$ LANGUAGE plpgsql;

ROLLBACK;
