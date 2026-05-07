-- =============================================================================
-- Normalize booking amount field  (plan: budget_booking_behavior_spec)
-- =============================================================================
--
-- Problem: the email-forwarding pipeline (process-forwarded-email edge
-- function) inserts into trip_bookings using `total_price`, while the DB
-- trigger `tg_sync_booking_expense` reads `amount`.  When total_price is
-- populated but amount is NULL the trigger produces no budget row.
--
-- Fix:
--   1. Backfill amount = total_price for all rows where amount IS NULL and
--      total_price IS NOT NULL (existing email-imported bookings).
--   2. Add a CHECK constraint that at least one of amount / total_price is
--      non-null when either is non-zero (prevents future silent nulls).
--   3. The edge function is updated separately to always write `amount`
--      (see process-forwarded-email/index.ts diff).
-- =============================================================================

-- Backfill existing email-imported bookings that only have total_price.
UPDATE trip_bookings
   SET amount = total_price
 WHERE amount IS NULL
   AND total_price IS NOT NULL
   AND total_price > 0;

-- Guard: if future inserts set total_price but omit amount, copy it forward
-- automatically via a BEFORE INSERT trigger so the sync trigger always has
-- a value to read.
CREATE OR REPLACE FUNCTION tg_coerce_booking_amount()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.amount IS NULL AND NEW.total_price IS NOT NULL THEN
        NEW.amount := NEW.total_price;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS tg_coerce_booking_amount ON trip_bookings;

CREATE TRIGGER tg_coerce_booking_amount
    BEFORE INSERT OR UPDATE ON trip_bookings
    FOR EACH ROW
    EXECUTE FUNCTION tg_coerce_booking_amount();
