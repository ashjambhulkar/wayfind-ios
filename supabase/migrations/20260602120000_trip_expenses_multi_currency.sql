-- Wave 0 (moved from Wave 2.4) — Multi-currency expense schema.
--
-- Plan §3.2 + §12.1: every expense must carry the original currency, the
-- amount in that currency, and the FX rate locked at capture time. This
-- schema MUST land in Wave 0 — before any Wave 1 receipt feature ships —
-- so users entering expenses today don't end up with NULL FX context after
-- the Pro multi-currency gate goes live in Wave 4.
--
-- Migration policy: existing rows get `original_amount = amount` and
-- `original_currency = currency` (1:1 self), `fx_rate_at_capture = 1.0`,
-- `fx_rate_date = spent_at`. This makes them trivially convertible later.

ALTER TABLE public.trip_expenses
  ADD COLUMN IF NOT EXISTS original_currency text,
  ADD COLUMN IF NOT EXISTS original_amount numeric(14, 2),
  ADD COLUMN IF NOT EXISTS fx_rate_at_capture numeric(14, 6),
  ADD COLUMN IF NOT EXISTS fx_rate_date date;

COMMENT ON COLUMN public.trip_expenses.original_currency IS
  'ISO 4217 code the expense was logged in (may differ from trip currency).';
COMMENT ON COLUMN public.trip_expenses.original_amount IS
  'Amount in original_currency. trip_expenses.amount stays the trip-currency value.';
COMMENT ON COLUMN public.trip_expenses.fx_rate_at_capture IS
  'Locked rate (original → trip). trip_amount = original_amount * fx_rate_at_capture.';
COMMENT ON COLUMN public.trip_expenses.fx_rate_date IS
  'Effective date for the rate, typically spent_at; lets us re-explain math later.';

-- Backfill existing rows so historical analytics don't break.
UPDATE public.trip_expenses
SET
  original_currency  = COALESCE(original_currency, currency),
  original_amount    = COALESCE(original_amount, amount),
  fx_rate_at_capture = COALESCE(fx_rate_at_capture, 1.0),
  fx_rate_date       = COALESCE(fx_rate_date, spent_at, CURRENT_DATE)
WHERE original_currency IS NULL
   OR original_amount IS NULL
   OR fx_rate_at_capture IS NULL
   OR fx_rate_date IS NULL;

-- Now that all rows have values, we can promote to NOT NULL with sane defaults.
-- We allow NULL on fx_rate_date to permit future free-form rows; iOS always
-- sets it on insert via the new BudgetService path.
ALTER TABLE public.trip_expenses
  ALTER COLUMN original_currency SET DEFAULT 'USD',
  ALTER COLUMN original_amount SET DEFAULT 0,
  ALTER COLUMN fx_rate_at_capture SET DEFAULT 1.0;

ALTER TABLE public.trip_expenses
  ALTER COLUMN original_currency SET NOT NULL,
  ALTER COLUMN original_amount SET NOT NULL,
  ALTER COLUMN fx_rate_at_capture SET NOT NULL;

ALTER TABLE public.trip_expenses
  ADD CONSTRAINT trip_expenses_original_amount_nonneg
    CHECK (original_amount >= 0) NOT VALID;
ALTER TABLE public.trip_expenses VALIDATE CONSTRAINT trip_expenses_original_amount_nonneg;

ALTER TABLE public.trip_expenses
  ADD CONSTRAINT trip_expenses_fx_rate_positive
    CHECK (fx_rate_at_capture > 0) NOT VALID;
ALTER TABLE public.trip_expenses VALIDATE CONSTRAINT trip_expenses_fx_rate_positive;

CREATE INDEX IF NOT EXISTS trip_expenses_fx_rate_date_idx
  ON public.trip_expenses (trip_id, fx_rate_date);
