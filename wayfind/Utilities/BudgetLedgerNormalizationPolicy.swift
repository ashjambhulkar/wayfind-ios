//
//  BudgetLedgerNormalizationPolicy.swift
//  wayfind
//
//  Production scope — *which* write paths run client-side trip-ledger normalization
//  (live FX + split redenomination) vs DB booking sync (pr-2: server parity or UI
//  disclosure when ledger ISO ≠ trip cap).
//
//  Keep this file updated when triggers, imports, or composers change.
//

import Foundation

// MARK: - Write sources

/// Origin of an expense row write, for policy and telemetry routing.
enum BudgetExpenseWriteSource: String, Sendable, CaseIterable, Hashable {
    /// `AddExpenseSheet` create/update through `BudgetService` on device.
    case manualComposer
    /// iOS “track booking cost” insert (`TripDetailView` / `BookingsScreenView`).
    case iosBookingCompanion
    /// Postgres `tg_sync_booking_expense` (and any other DB-only insert today).
    case databaseAutoSync
    /// Future: forwarded-email / server ingest pipeline.
    case emailImportForward
    /// Fallback when caller cannot classify — treat as **not** client-normalized.
    case unknown
}

// MARK: - Trip cap currency changes (v1)

/// What happens to **existing** `trip_expenses` when the owner changes
/// `trips.budget_currency` (pr-3 may replace this enum with automated reconversion).
enum TripBudgetCapCurrencyChangeBehaviorV1: Sendable, Equatable {
    /// Existing rows are **not** mass-reconverted. New saves use the new cap ISO.
    /// Rollups may mix ledger currencies until users edit or a backfill ships.
    /// Owner confirmation before changing cap ISO when expenses exist — see `EditTripBudgetSheet`.
    case existingRowsUnchangedNewWritesUseNewCap
}

// MARK: - Policy surface

enum BudgetLedgerNormalizationPolicy {

    /// v1 contract for trip cap ISO edits (see pr-3 for product UX + automation).
    static let tripBudgetCapCurrencyChangeBehavior: TripBudgetCapCurrencyChangeBehaviorV1 =
        .existingRowsUnchangedNewWritesUseNewCap

    /// Until pr-2, Postgres booking sync writes `original_*` = booking line and
    /// `fx_rate_at_capture = 1` without converting into `trips.budget_currency`.
    static let serverAutoSyncUsesBookingLineAsLedgerUntilPR2 = true

    /// Paths that run **device** normalization (Frankfurter / Edge fallback) and
    /// persist ledger `amount` + `currency` in trip budget ISO.
    static func appliesClientTripLedgerNormalization(_ source: BudgetExpenseWriteSource) -> Bool {
        switch source {
        case .manualComposer, .iosBookingCompanion:
            return true
        case .databaseAutoSync, .emailImportForward, .unknown:
            return false
        }
    }

    /// Short copy for settings / internal tools — **not** end-user marketing.
    static func engineeringNote(for source: BudgetExpenseWriteSource) -> String {
        switch source {
        case .manualComposer, .iosBookingCompanion:
            return "Client-normalized to trip budget currency at save (locked FX metadata)."
        case .databaseAutoSync:
            return serverAutoSyncUsesBookingLineAsLedgerUntilPR2
                ? "DB auto-sync (v1): booking currency stored as ledger until server FX parity (pr-2)."
                : "DB auto-sync: server uses trip-budget ledger (pr-2 complete)."
        case .emailImportForward:
            return "Email import not wired — classify source before enabling normalization."
        case .unknown:
            return "Unknown write source — do not assume client normalization ran."
        }
    }

    // MARK: - Inference (persisted `TripExpense` rows)

    /// Best-effort classification from stored flags. Extend when email import
    /// or other writers add discriminant columns.
    static func inferWriteSource(from expense: TripExpense) -> BudgetExpenseWriteSource {
        if expense.isAutoSynced { return .databaseAutoSync }
        return .manualComposer
    }

    /// `true` when this row came from **DB booking sync** and its ledger ISO
    /// differs from the trip’s budget cap — headline totals in the cap
    /// currency exclude this row’s amount (it still appears under its own ISO).
    static func bookingSyncedLedgerDiffersFromTripBudgetCap(
        expense: TripExpense,
        tripBudgetCurrency: String
    ) -> Bool {
        guard expense.isAutoSynced else { return false }
        guard serverAutoSyncUsesBookingLineAsLedgerUntilPR2 else { return false }
        let cap = BudgetCurrencyProductPolicy.normalizedTripBudgetCurrencyCode(tripBudgetCurrency)
        let ledger = BudgetCurrencyProductPolicy.normalizedTripBudgetCurrencyCode(expense.currencyCode)
        return ledger != cap
    }

    /// Whether **any** snapshot row needs the booking-vs-trip-cap disclaimer.
    static func hasBookingSyncTripCapMismatch(
        expenses: [TripExpense],
        tripBudgetCurrency: String
    ) -> Bool {
        expenses.contains { bookingSyncedLedgerDiffersFromTripBudgetCap(expense: $0, tripBudgetCurrency: tripBudgetCurrency) }
    }

    /// Short user-facing explanation (trip cap ISO already normalized).
    static func userFacingBookingSyncTripCapMismatchExplanation(tripBudgetCurrency: String) -> String {
        let cap = BudgetCurrencyProductPolicy.normalizedTripBudgetCurrencyCode(tripBudgetCurrency)
        return "Some booking-synced expenses stay in the booking’s currency. The trip total in \(cap) only sums rows stored in \(cap); edit an expense to convert it if needed."
    }

    // MARK: - Trip cap ISO change (pr-3)

    /// When the owner picks a **new** trip budget cap ISO and the trip already
    /// has expenses, we require an explicit confirmation (no mass reconversion).
    static func shouldConfirmTripCapCurrencyChange(
        previousCapCurrency: String,
        nextCapCurrency: String,
        existingExpenseCount: Int
    ) -> Bool {
        guard existingExpenseCount > 0 else { return false }
        let prev = BudgetCurrencyProductPolicy.normalizedTripBudgetCurrencyCode(previousCapCurrency)
        let next = BudgetCurrencyProductPolicy.normalizedTripBudgetCurrencyCode(nextCapCurrency)
        return prev != next
    }

    /// Body copy for the trip-cap currency change confirmation dialog.
    static func userFacingTripCapCurrencyChangeConfirmationDetail(
        previousCapCurrency: String,
        nextCapCurrency: String
    ) -> String {
        let prev = BudgetCurrencyProductPolicy.normalizedTripBudgetCurrencyCode(previousCapCurrency)
        let next = BudgetCurrencyProductPolicy.normalizedTripBudgetCurrencyCode(nextCapCurrency)
        return "Changing the trip budget cap from \(prev) to \(next) won’t convert existing expenses. Each line keeps its saved currency; new expenses you add in the app will use \(next) for trip-ledger normalization."
    }

    // MARK: - Manual expense edit FX (pr-4)

    /// When updating a hand-entered expense whose **original** currency differs
    /// from the trip cap, reuse the stored multiplier + quote date if the user
    /// did not change the **original ISO** or the **expense calendar day**.
    /// Changing day or currency triggers a fresh FX fetch on save.
    static func shouldPreserveLockedFxQuoteOnManualExpenseUpdate(
        persistedRow: TripExpense,
        composerEntry: TripExpense,
        tripBudgetCurrency: String
    ) -> Bool {
        let tripCode = BudgetCurrencyProductPolicy.normalizedTripBudgetCurrencyCode(tripBudgetCurrency)
        let composerOrig =
            PreferredCurrencyFormatting.normalizeInput(composerEntry.currencyCode) ?? tripCode
        guard composerOrig != tripCode else { return false }
        guard !persistedRow.isAutoSynced else { return false }
        let writeSource = inferWriteSource(from: persistedRow)
        guard appliesClientTripLedgerNormalization(writeSource) else { return false }

        let persistedLedger =
            BudgetCurrencyProductPolicy.normalizedTripBudgetCurrencyCode(persistedRow.currencyCode)
        guard persistedLedger == tripCode else { return false }

        let persistedOrig =
            BudgetCurrencyProductPolicy.normalizedTripBudgetCurrencyCode(persistedRow.originalCurrencyCode)
        guard persistedOrig == composerOrig else { return false }

        let priorDay = ExpenseDateFormatter.string(from: persistedRow.expenseDate)
        let nextDay = ExpenseDateFormatter.string(from: composerEntry.expenseDate)
        return priorDay == nextDay
    }
}


// =============================================================================
