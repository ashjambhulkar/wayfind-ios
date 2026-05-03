//
//  BudgetCurrencyProductPolicy.swift
//  wayfind
//
//  Wave — full budget currency conversion (task 1: product rules as code contract).
//
//  ----------------------------------------------------------------------------
//  PRODUCT RULES (design / PM — keep in sync when behavior changes)
//  ----------------------------------------------------------------------------
//
//  **What users are trying to do**
//  • Log expenses in the currency that matches the receipt or card charge.
//  • See trip spend and budget progress in a currency they understand day-to-day.
//  • Settle with travel partners without the app implying false precision.
//
//  **Display currency — two lenses**
//  1. *Trip budget currency* — from `Trip.budgetCurrencyCode` (owner-set cap). Used
//     for the default “trip” view: totals and category caps align with this code.
//  2. *Personal display currency* — from **Profile → Preferred currency** when
//     the user has set one; otherwise **device locale currency**; final fallback
//     `USD`. Used when the user opts into “show my numbers in home/preferred”
//     (toggle in budget header; Pro-gated today — see below).
//
//  The in-app toggle switches between (1) and (2) for *headline* conversion UX;
//  underlying ledger rows still store each expense’s entered currency.
//
//  **Settlements**
//  • All balances, split lines, and “settle up” suggestions stay **per ISO
//    currency**. We do **not** net debts across currencies or show a single
//    “you owe” that blends FX unless a future version explicitly adds that with
//    clear copy and consent. Real payments happen in one currency at a time.
//
//  **Pro vs free (current product contract)**
//  • **Free:** Full per-currency ledger, trip-currency totals, mixed-currency
//    disclosure banner. No paywall for entering mixed-currency expenses.
//  • **Pro:** Toggling the budget header to view headline totals converted into
//    *personal display currency* (matches existing paywall: `.currencyMulti`).
//  • Later waves may move or extend Pro (e.g. CSV in converted columns); update
//    `proFeatureScope` if that changes.
//
//  **Production ledger scope (v1)**
//  • Which flows normalize into `trips.budget_currency` on save — trip cap
//    changes, and **when edits re-fetch FX vs reuse the stored multiplier**
//    (same original ISO + same expense calendar day) — live in
//    ``BudgetLedgerNormalizationPolicy`` (pr-2 / pr-3 / pr-4).
//
//  **FX resilience (pr-5)** — `CurrencyService` retries transient network
//  failures with bounded backoff, then disk + yesterday fallbacks. Saving a
//  mixed-currency expense still **hard-fails** if no quote is available (no
//  offline queue in v1); the error toast includes a short **support reference**.
//
//  **FX observability (pr-6)** — `BudgetFxTelemetry` emits `os_signpost`
//  events (Instruments → Budget / FX) and Sentry **breadcrumbs** for
//  `fx_fetch_success`, `fx_fetch_fallback`, and `fx_save_blocked` with
//  coarse fields (base ISO, quote date, latency ms, provider); no URLs or tokens.
//
//  **FX provider compliance (pr-7)** — Frankfurter is free for commercial use
//  (see frankfurter.app FAQ); backup exchangerate.host is governed by
//  APILayer terms. Disclosure lives in Profile → **Exchange rate data**
//  (`ExchangeRateAttributionSheet` + `BudgetFxProviderAttribution`).
//
//  **FX cost / abuse (pr-8)** — iOS coalesces concurrent identical network
//  fetches (`CurrencyRateFetchDedupeKey`) and allows at most two concurrent
//  FX network stacks. Server-side: monitor `currency-rates` Edge volume
//  (see function header comment).
//
//  **FX DB integrity (pr-9)** — `20260605150000_trip_expenses_fx_data_integrity_pr9.sql`
//  documents RLS/trigger coverage for FX columns, backfills NULL
//  `fx_rate_date`, and normalizes ISO codes. No new RLS: existing row policies
//  already gate all columns.
//
//  **FX integration tests (pr-10)** — `CurrencyRateAPIContractTests` locks the
//  Frankfurter + Edge JSON shapes; `BudgetExpenseMockRoundTripTests` exercises
//  `MockDataService` add/update (DEBUG mock FX multiplier). Live Supabase E2E
//  stays a separate pipeline with credentials.
//
//  **Mock / staging parity (pr-11)** — `AppConfig.mockBudgetForeignToTripLedgerMultiplier`
//  is 1.1 in DEBUG (deterministic) and 1 in Release; staging uses real Supabase
//  URLs/keys in this file (see `AppConfig` comment). Never ship service_role in-app.
//
//  **Support runbook (pr-12)** — `docs/budget-fx-support-runbook.md` (FX errors,
//  how to verify `trip_expenses` math, escalation).
//
//  ----------------------------------------------------------------------------
//

import Foundation

/// Namespace for agreed budget-currency behavior. Downstream features (rollups,
/// headers, persistence) should call these helpers instead of re-deriving rules.
enum BudgetCurrencyProductPolicy {

    // MARK: - Pro scope (marketing / paywall parity)

    /// When `true`, switching the budget summary from trip currency to converted
    /// personal display currency requires Wayfind Pro (existing header behavior).
    static let proFeatureTripVersusPersonalHeaderToggle = true

    // MARK: - Settlement presentation

    /// Settlements and balance math are strictly single-currency per bucket.
    /// UI must not present a cross-currency “net you owe” without a new product pass.
    static let settlementsArePerCurrencyOnly = true

    // MARK: - Resolvers

    /// Normalizes the trip headline / cap currency (ISO 4217, uppercased).
    static func normalizedTripBudgetCurrencyCode(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if trimmed.isEmpty { return "USD" }
        return String(trimmed.prefix(PreferredCurrencyFormatting.codeMaxLength))
    }

    /// Currency used for “home / preferred” headline conversion when the user
    /// has turned **on** the personal lens (after Pro check at call site).
    ///
    /// Priority: profile preferred (if non-empty after normalization) →
    /// `localeCurrencyCode` (typically `Locale.current.currency?.identifier`) →
    /// `USD`.
    static func personalDisplayCurrencyCode(
        preferredFromProfile: String?,
        localeCurrencyCode: String?
    ) -> String {
        if let fromProfile = PreferredCurrencyFormatting.normalizeInput(preferredFromProfile ?? "") {
            return fromProfile
        }
        let trimmed = (localeCurrencyCode ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        if trimmed.isEmpty { return "USD" }
        return String(trimmed.prefix(PreferredCurrencyFormatting.codeMaxLength))
    }
}

// MARK: - Manual QA checklist (release verification)

/*
 Trip budget currency & FX — manual QA
 -------------------------------------
 1. Solo trip: add expense in trip currency; totals and CSV show matching ledger/original.
 2. Add expense in a foreign currency with network on; ledger converts to trip cap ISO; row shows two lines.
 3. Airplane mode add foreign expense: expect error toast, no phantom row (rollback).
 4. Edit foreign expense amount; splits and ledger refresh after save.
 5. Multi-member equal split in EUR with trip USD: each share in USD sums to trip total.
 6. Settlements: two currencies produce two suggestion cards; settle one currency only.
 7. Pro: header toggle trip ↔ preferred (profile empty → locale); churn to free resets toggle.
 8. Booking flow (iOS): cost tracked; DB row has original_* + fx columns populated (see migration).
 9. CSV: open in Numbers — UTF-8 BOM, new FX columns populated.
 10. Profile preferred currency change → reopen budget → header uses new code without relaunch.
 11. Booking-synced expense in EUR with trip cap USD: info banner + row caption “Not in USD trip total”; summary USD excludes that row’s amount.
 12. With ≥1 expense, change trip cap USD→GBP in Edit Trip Budget: confirmation appears; Cancel leaves sheet open unchanged; Continue saves and new manual expenses use GBP.
 13. Edit foreign expense: change amount only (same day + same receipt currency) saves without new FX fetch; change expense date → new rate path (airplane mode should error if fetch fails).
 14. Airplane mode + new foreign expense: toast includes “Support reference” and an 8-character code; turn Wi‑Fi on and retry — succeeds without duplicate if user taps Save once.
 15. With Sentry configured, reproduce a successful foreign quote: breadcrumbs show `fx_fetch_success` with `latency_ms` and `provider` (frankfurter or edge).
 16. Profile → Exchange rate data: sheet opens; Frankfurter and exchangerate.host links work; Done dismisses.
 17. Rapid duplicate FX taps (same currency pair + date): only one network stack runs; no duplicate Edge rows in Supabase logs for the same millisecond burst.
 18. After pr-9 migration: no `trip_expenses` rows with NULL `fx_rate_date`; `currency` / `original_currency` are uppercase trimmed ISO codes.
 19. CI: `wayfindTests` — `CurrencyRateAPIContractTests` + `BudgetExpenseMockRoundTripTests` pass (FX JSON fixtures + mock budget round-trip).
 20. Release archive: `mockBudgetForeignToTripLedgerMultiplier` is 1 (no fake 1.1); DEBUG previews still show 1.1 mock conversion when offline.
 21. Support: `docs/budget-fx-support-runbook.md` is current for FX failure triage and expense math verification.
*/


// =============================================================================
