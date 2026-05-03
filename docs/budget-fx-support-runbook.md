# Budget FX — Support Runbook

Operational guide for **mixed-currency expenses**, exchange-rate failures, and “wrong number” tickets. Product rules live in `wayfind/Utilities/BudgetCurrencyProductPolicy.swift`; implementation in `CurrencyService`, `BudgetService`, and `TripExpenseLedgerNormalizer`.

## What users should expect

- **Trip budget currency** (`trips.budget_currency`): headline totals and each expense’s stored **`amount`** + **`currency`** (after save) align with this ISO code when the expense was entered in another currency.
- **Original receipt currency** is preserved as **`original_amount`** / **`original_currency`**.
- **Locked quote**: **`fx_rate_at_capture`** and **`fx_rate_date`** record the multiplier and the calendar day used for that save (see Profile → **Exchange rate data** for provider disclosure).

There is **no offline queue** for new foreign quotes in v1: if the app cannot obtain a rate, save fails and nothing new is written.

## Common symptoms and first responses

| Symptom | Likely cause | First step |
| --- | --- | --- |
| Toast about exchange rates / “try again”; **Support reference** shown | No usable FX after retries (airplane mode, provider outage, bad Edge response) | Ask user to retry on Wi‑Fi/cellular; capture **support reference** + approximate time (UTC). |
| Same expense, amount “changed” after editing **date** | New calendar day → app may **re-fetch** FX; rate moved | Expected if policy allows refresh; compare `fx_rate_date` before/after in Supabase (see below). |
| Amount unchanged after **amount-only** edit, same receipt currency, same day | **pr-4** path reuses stored multiplier | Expected; verify `fx_rate_at_capture` unchanged. |
| User insists total is “wrong” vs bank | Rounding to cents on **trip** side; bank used different day or FX | Walk through verification math below; do not promise inter-bank spot parity. |

## Verifying an expense’s math (support checklist)

Use Supabase **Table Editor** or SQL (read-only) on `public.trip_expenses` for the row `id`.

1. **Same currency**  
   If `original_currency` = `currency` (trip cap): expect `fx_rate_at_capture` = `1` and `amount` ≈ `original_amount` (money rounding only).

2. **Foreign → trip**  
   - `fx_rate_date` should be a **calendar date** (YYYY-MM-DD), not null on normalized rows (post pr-9 migration).  
   - Sanity: `amount` should match **`original_amount * (trip units per 1 original)`** rounded to money scale, with **`fx_rate_at_capture`** ≈ `amount / original_amount` at 6 decimal places (see `TripExpenseLedgerNormalizer`).  
   - Recompute externally only if needed: use the same **date** and pair; Frankfurter is documented in-app under Profile → **Exchange rate data**.

3. **Splits**  
   Split lines are in **trip currency** for that expense; their sum should match **`amount`** for the row (modulo equal-split cent distribution).

4. **Booking-synced rows**  
   If `booking_id` is set, booking edits may still update the row until the user edits the expense in-app (then `is_auto_synced` becomes false). Check booking amount vs `original_amount` / `amount` consistency.

## Logs and breadcrumbs (engineering)

- **iOS**: With Sentry configured, look for breadcrumbs tagged around **`fx_fetch_success`**, **`fx_fetch_fallback`**, **`fx_save_blocked`** (`BudgetFxTelemetry`) — coarse fields only (e.g. base ISO, quote date, latency, provider).  
- **Instruments**: `os_signpost` “Budget / FX” intervals for local repro.  
- **Edge**: `currency-rates` function — see header comment in `supabase/functions/currency-rates/index.ts` for volume / abuse monitoring.

Never paste **user tokens**, **full request URLs with keys**, or **PII** into public tickets.

## Escalation

1. **Support reference** + `trip_id`, `trip_expenses.id`, user’s **original** amount/currency and **trip cap** currency — attach screenshot of error if available.  
2. **Engineering** if: repeated failures across users, obvious bad multiplier (e.g. inverted pair), or `fx_rate_date` / ISO codes clearly inconsistent with product rules.  
3. **Provider / Edge** if: Frankfurter or backup returns systematic errors for a currency pair or date — verify with `CurrencyRateAPIContractTests` fixtures and a manual curl for that date (do not ship secrets in tickets).

## Related docs

- `wayfind/Docs/COLLABORATIVE_BUDGET_QA.md` — manual QA matrix including FX rows.  
- `docs/MODULES.md` (Budget section) — primary Swift files for budget + FX.  
- `docs/observability-runbook.md` — Sentry / Loki usage and privacy limits.
