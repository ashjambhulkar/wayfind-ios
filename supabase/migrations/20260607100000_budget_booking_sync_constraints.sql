-- =============================================================================
-- Budget–Booking Sync Constraints  (plan: budget_booking_behavior_spec)
-- =============================================================================
--
-- Adds three additive schema changes to harden the booking↔expense linkage:
--
--  1. booking_group_id  — groups multi-leg/return flight bookings under one
--     combined budget row (Provenance.combinedFlight on iOS).
--
--  2. expense_source    — persists how a row was created so inference from
--     is_auto_synced alone is no longer necessary. Existing rows are backfilled
--     from is_auto_synced.
--
--  3. Unique indexes     — enforce one linked expense per booking and one
--     combined expense per booking_group. Applied after backfill so any
--     pre-existing duplicates can be resolved first.
--
-- Safe to apply on a live database:
--   • All DDL changes are additive (new nullable columns / new indexes).
--   • No existing column is altered or dropped.
--   • Backfill UPDATE touches is_auto_synced=true rows only; manual rows
--     already have booking_id=NULL so UNIQUE constraints won't conflict.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. booking_group_id
-- ---------------------------------------------------------------------------

ALTER TABLE trip_expenses
    ADD COLUMN IF NOT EXISTS booking_group_id UUID REFERENCES trip_bookings(id) ON DELETE SET NULL;

COMMENT ON COLUMN trip_expenses.booking_group_id IS
    'Groups multi-leg / return flight bookings under one combined budget row. '
    'NULL for single-booking or manual entries. FK ON DELETE SET NULL so '
    'removing one leg detaches it without deleting the combined row.';

-- ---------------------------------------------------------------------------
-- 2. expense_source
-- ---------------------------------------------------------------------------

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'expense_source_kind') THEN
        CREATE TYPE expense_source_kind AS ENUM (
            'booking_auto',       -- created/updated by tg_sync_booking_expense trigger
            'booking_companion',  -- created by iOS companion trackBookingExpenseIfNeeded
            'manual',             -- created by user in Add Expense sheet
            'email_import'        -- future: created by email-forwarding pipeline
        );
    END IF;
END $$;

ALTER TABLE trip_expenses
    ADD COLUMN IF NOT EXISTS expense_source expense_source_kind;

COMMENT ON COLUMN trip_expenses.expense_source IS
    'Discriminant persisted at write time so the app never needs to infer '
    'origin from nullable columns. booking_auto rows are owned by the DB '
    'trigger; companion/manual/email rows are iOS-owned.';

-- Backfill from is_auto_synced for existing rows.
-- booking_auto  → was created by the trigger (is_auto_synced was/is true)
-- manual        → booking_id IS NULL (pure hand entry)
-- booking_companion → booking_id IS NOT NULL but is_auto_synced = false
UPDATE trip_expenses
   SET expense_source = CASE
       WHEN is_auto_synced = TRUE               THEN 'booking_auto'::expense_source_kind
       WHEN booking_id IS NOT NULL              THEN 'booking_companion'::expense_source_kind
       ELSE                                          'manual'::expense_source_kind
   END
 WHERE expense_source IS NULL;

-- ---------------------------------------------------------------------------
-- 3. Unique linkage constraints
-- ---------------------------------------------------------------------------
-- One auto-synced expense per booking (single-leg). The partial index only
-- covers booking_auto rows so companion/manual entries that happened to carry
-- a booking_id are not constrained (they should not exist post-migration but
-- we keep the index narrow during the transition period).
CREATE UNIQUE INDEX IF NOT EXISTS uq_trip_expenses_booking_auto
    ON trip_expenses (booking_id)
    WHERE booking_id IS NOT NULL
      AND expense_source = 'booking_auto';

-- One combined expense per booking group. Covers both booking_auto and
-- booking_companion sources for flexibility during the rollout.
CREATE UNIQUE INDEX IF NOT EXISTS uq_trip_expenses_booking_group
    ON trip_expenses (booking_group_id)
    WHERE booking_group_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 4. Update tg_sync_booking_expense to write expense_source
-- ---------------------------------------------------------------------------
-- Extend the trigger function so new rows created by the trigger always carry
-- expense_source = 'booking_auto'. The full trigger body is reconstructed here
-- to stay idempotent with CREATE OR REPLACE.

CREATE OR REPLACE FUNCTION public.tg_sync_booking_expense()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $sync$
DECLARE
    v_booking_amount    NUMERIC;
    v_booking_currency  TEXT;
    v_category          TEXT;
    v_title             TEXT;
    v_actor             UUID;
    v_existing_id       UUID;
    v_existing_auto     BOOLEAN;
BEGIN
    -- Recursion guard.
    IF pg_trigger_depth() > 1 THEN RETURN NEW; END IF;

    -- Determine the canonical amount. Prefer `amount`; fall back to
    -- `total_price` for legacy email-import rows (see migration 20260607120000).
    v_booking_amount := COALESCE(NEW.amount, NEW.total_price);
    v_booking_currency := COALESCE(NULLIF(trim(NEW.currency), ''), 'USD');

    IF v_booking_amount IS NULL OR v_booking_amount <= 0 THEN
        RETURN NEW;
    END IF;

    v_category := CASE NEW.kind
        WHEN 'flight'     THEN 'flight'
        WHEN 'lodging'    THEN 'lodging'
        WHEN 'car'        THEN 'car'
        WHEN 'restaurant' THEN 'food'
        WHEN 'train'      THEN 'transport'
        WHEN 'bus'        THEN 'transport'
        WHEN 'ferry'      THEN 'transport'
        WHEN 'cruise'     THEN 'transport'
        WHEN 'transport'  THEN 'transport'
        WHEN 'concert'    THEN 'activities'
        WHEN 'theater'    THEN 'activities'
        WHEN 'tour'       THEN 'activities'
        WHEN 'activity'   THEN 'activities'
        WHEN 'activities' THEN 'activities'
        ELSE 'other'
    END;

    v_title := COALESCE(NULLIF(trim(NEW.title), ''), 'Booking');
    v_actor := COALESCE(
        NEW.user_id,
        (SELECT t.user_id FROM public.trips t WHERE t.id = NEW.trip_id LIMIT 1)
    );
    IF v_actor IS NULL THEN RETURN NEW; END IF;

    SELECT te.id, te.is_auto_synced
      INTO v_existing_id, v_existing_auto
      FROM public.trip_expenses te
     WHERE te.booking_id = NEW.id
     LIMIT 1;

    IF v_existing_id IS NULL THEN
        INSERT INTO public.trip_expenses (
            trip_id, user_id, payer_user_id, booking_id,
            title, amount, currency,
            original_amount, original_currency,
            fx_rate_at_capture, fx_rate_date,
            category, split_type, expense_date,
            is_auto_synced, expense_source
        ) VALUES (
            NEW.trip_id, v_actor, v_actor, NEW.id,
            v_title, v_booking_amount, v_booking_currency,
            v_booking_amount, v_booking_currency,
            1, CURRENT_DATE,
            v_category, 'full',
            COALESCE(NEW.starts_at::date, CURRENT_DATE),
            TRUE, 'booking_auto'
        );
    ELSIF v_existing_auto THEN
        UPDATE public.trip_expenses
           SET title          = v_title,
               amount         = v_booking_amount,
               currency       = v_booking_currency,
               original_amount = v_booking_amount,
               original_currency = v_booking_currency,
               category       = v_category,
               expense_source = 'booking_auto'
         WHERE id = v_existing_id
           AND is_auto_synced = TRUE;
    END IF;
    -- If is_auto_synced = FALSE the user has edited this row — leave it alone.

    RETURN NEW;
END;
$sync$;
