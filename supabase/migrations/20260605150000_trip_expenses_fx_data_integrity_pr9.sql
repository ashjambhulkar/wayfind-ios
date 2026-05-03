-- pr-9 — Trip expense FX data integrity (review + safe backfill).
--
-- RLS / triggers (review only; no policy changes):
--   • `trip_expenses` row policies from 20260419120000 remain table-wide:
--     SELECT uses `can_view_trip(trip_id)`; INSERT/UPDATE/DELETE use
--     `can_edit_trip(trip_id)` (+ insert user_id guard). PostgreSQL applies
--     policies to whole rows — new FX columns (`original_*`, `fx_*`) are
--     covered automatically; clients cannot bypass RLS for those fields alone.
--   • `expense_splits` editor policies (20260501120000) key off `trip_id` +
--     `can_edit_trip`; unchanged by FX columns on parent expenses.
--   • `trip_expenses_set_updated_at` (20260419120000) still bumps `updated_at`
--     on UPDATE including FX field edits.
--   • Booking sync trigger `tg_sync_booking_expense` is defined in
--     20260603120100_booking_expense_sync_fx_columns.sql (replaces earlier
--     version) and keeps `original_*` + `fx_*` aligned for auto-synced rows.
--
-- Backfill / hygiene:
--   • Any NULL `fx_rate_date` (allowed by 20260602120000) gets a stable date
--     from `expense_date`, legacy `spent_at`, or `created_at` UTC date.
--   • Normalize `currency` / `original_currency` to trimmed UPPERCASE ASCII
--     so CHECK constraints and iOS ISO formatting stay aligned.

COMMENT ON TABLE public.trip_expenses IS
  'Per-trip expense line items; single source of truth for collaborative budget. '
  'Multi-currency ledger + originals (20260602120000). RLS: can_view_trip / can_edit_trip (20260419120000); '
  'FX columns use the same row policies (pr-9). Booking sync: tg_sync_booking_expense (20260603120100).';

-- ─── 1. fx_rate_date backfill (nullable column; iOS prefers non-null) ────────
UPDATE public.trip_expenses
SET fx_rate_date = COALESCE(
  fx_rate_date,
  expense_date,
  spent_at,
  (created_at AT TIME ZONE 'UTC')::date,
  CURRENT_DATE
)
WHERE fx_rate_date IS NULL;

-- ─── 2. ISO code hygiene (trim + uppercase; do not truncate valid codes) ────
UPDATE public.trip_expenses
SET currency = upper(trim(currency))
WHERE currency IS DISTINCT FROM upper(trim(currency));

UPDATE public.trip_expenses
SET original_currency = upper(trim(original_currency))
WHERE original_currency IS DISTINCT FROM upper(trim(original_currency));

-- Empty / whitespace currency would violate app expectations — fall back.
UPDATE public.trip_expenses
SET currency = 'USD'
WHERE trim(currency) = '';

UPDATE public.trip_expenses
SET original_currency = currency
WHERE trim(original_currency) = '';

