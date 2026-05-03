//
//  BudgetService.swift
//  wayfind
//
//  All Supabase reads + writes for the collaborative budget feature:
//
//   • `trip_expenses`         — per-row expense ledger
//   • `expense_splits`        — per-user owed share (denormalised `trip_id`)
//   • `trip_budgets`          — per-category planned spend
//   • `expense_settlements`   — payment receipts ("I paid you back")
//
//  Monetary fields use `DecimalCodec` end-to-end so PostgREST `numeric`
//  columns survive without precision loss (see `DecimalCodec.swift`).
//
//  Mock parity lives in `MockBudgetService` (in `MockDataService.swift`) so
//  Previews, unit tests, and the offline build all see the same model surface.
//
//  Categorisation: this file owns the network DTOs + mapping. Anything UI-side
//  (rollups, derived state, optimistic mutation) lives in `BudgetViewModel`.
//  Ledger-normalization scope for v1 write paths: ``BudgetLedgerNormalizationPolicy``.
//

import Foundation
import Supabase

// MARK: - Write errors

/// Opaque support handle for FX quote failures (pr-5). Keep stable format
/// (length + charset) so support can grep logs later.
enum BudgetFxQuoteSupport {
    static func makeReference() -> String {
        UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .prefix(8)
            .uppercased()
    }
}

enum BudgetExpenseWriteError: LocalizedError, Sendable {
    /// Live quote failed after retries / cache; `supportReference` is shown in the toast.
    case fxUnavailable(supportReference: String)

    var errorDescription: String? {
        switch self {
        case .fxUnavailable(let ref):
            return String(
                localized: "Couldn’t fetch an exchange rate for that date. Check your connection and try again. Support reference: \(ref)."
            )
        }
    }
}

// MARK: - Public API surface (mirrored on `DataService`)

@MainActor
final class BudgetService {
    static let shared = BudgetService()
    private init() {}

    private var client: SupabaseClient? { AuthSessionService.shared.client }

    // MARK: - Bulk fetch (one trip)

    /// Loads expenses + splits + per-category budgets + settlements for a single
    /// trip in parallel. The four queries are independent, so we fan out via
    /// `async let` and rely on RLS to drop rows the caller can't see.
    ///
    /// `BudgetViewModel.reload` calls this once on first appearance and once
    /// per Realtime burst; we do not stream individual mutations into the
    /// model — replacing the snapshot is simpler and the payload is tiny
    /// (single trip, mostly < 100 rows).
    func fetchAll(tripId: UUID) async throws -> BudgetSnapshot {
        guard let client else { throw SupabaseManagerError.notConfigured }
        let tripIdLower = tripId.uuidString.lowercased()

        async let expensesTask: [TripExpenseRow] = client
            .from("trip_expenses")
            .select()
            .eq("trip_id", value: tripIdLower)
            .order("expense_date", ascending: false)
            .execute()
            .value

        async let splitsTask: [ExpenseSplitRow] = client
            .from("expense_splits")
            .select()
            .eq("trip_id", value: tripIdLower)
            .execute()
            .value

        async let budgetsTask: [TripBudgetRow] = client
            .from("trip_budgets")
            .select()
            .eq("trip_id", value: tripIdLower)
            .execute()
            .value

        async let settlementsTask: [ExpenseSettlementRow] = client
            .from("expense_settlements")
            .select()
            .eq("trip_id", value: tripIdLower)
            .order("created_at", ascending: false)
            .execute()
            .value

        let (expenseRows, splitRows, budgetRows, settlementRows) =
            try await (expensesTask, splitsTask, budgetsTask, settlementsTask)

        return BudgetSnapshot(
            expenses: expenseRows.map { $0.asModel },
            splits: splitRows.map { $0.asModel },
            budgets: budgetRows.map { $0.asModel },
            settlements: settlementRows.map { $0.asModel }
        )
    }

    // MARK: - Trip total budget (owner only via RLS on `trips`)

    /// Updates the headline trip-level budget. Pass `nil` to clear it back to
    /// "not set" — the migration changes `trips.total_budget` to nullable so
    /// the UI can distinguish "$0 budget" from "no budget set".
    func updateTripTotalBudget(
        tripId: UUID,
        totalBudget: Decimal?,
        currency: String
    ) async throws {
        guard let client else { throw SupabaseManagerError.notConfigured }
        let payload = TripTotalBudgetUpdate(
            total_budget: totalBudget.map(DecimalCodec.init),
            budget_currency: currency
        )
        try await client
            .from("trips")
            .update(payload)
            .eq("id", value: tripId.uuidString.lowercased())
            .execute()
    }

    // MARK: - Expenses

    /// Inserts a new expense and replaces its splits in a single round-trip.
    /// `userEntry` must carry the **typed** total in ``TripExpense/currencyCode``;
    /// amounts are normalized to `tripBudgetCurrency` for ledger columns and
    /// splits. We rely on the DB trigger to mirror `trip_id` onto each split row.
    @discardableResult
    func addExpense(
        _ userEntry: TripExpense,
        splits: [ExpenseSplit],
        tripBudgetCurrency: String
    ) async throws -> (expense: TripExpense, splits: [ExpenseSplit]) {
        guard let client else { throw SupabaseManagerError.notConfigured }
        guard let userId = try? await client.auth.session.user.id else {
            throw SupabaseManagerError.notAuthenticated
        }
        let normalized = try await Self.normalizeUserExpenseForTripLedger(
            userEntry: userEntry,
            splits: splits,
            tripBudgetCurrency: tripBudgetCurrency
        )
        let ledger = normalized.ledger
        let ledgerSplits = normalized.splits

        let payload = TripExpenseInsert(
            id: ledger.id,
            trip_id: ledger.tripId,
            user_id: userId,
            payer_user_id: ledger.payerUserId ?? userId,
            booking_id: ledger.bookingId,
            title: ledger.title,
            amount: DecimalCodec(ledger.amount),
            currency: ledger.currencyCode,
            original_currency: ledger.originalCurrencyCode,
            original_amount: DecimalCodec(ledger.originalAmount),
            fx_rate_at_capture: DecimalCodec(ledger.fxRateAtCapture),
            fx_rate_date: ExpenseDateFormatter.string(from: ledger.fxRateDate),
            category: ledger.category.rawValue,
            split_type: ledger.splitType.rawValue,
            expense_date: ExpenseDateFormatter.string(from: ledger.expenseDate),
            notes: ledger.notes,
            is_auto_synced: false
        )
        let inserted: TripExpenseRow = try await client
            .from("trip_expenses")
            .insert(payload, returning: .representation)
            .select()
            .single()
            .execute()
            .value

        if !ledgerSplits.isEmpty {
            let splitInserts = ledgerSplits.map { split in
                ExpenseSplitInsert(
                    expense_id: inserted.id,
                    trip_id: inserted.trip_id,
                    user_id: split.userId,
                    amount: DecimalCodec(split.amount),
                    currency: split.currencyCode,
                    is_accepted: split.isAccepted
                )
            }
            try await client
                .from("expense_splits")
                .insert(splitInserts)
                .execute()
        }

        let persistedSplits = ledgerSplits.map { split in
            ExpenseSplit(
                id: split.id,
                expenseId: inserted.id,
                tripId: inserted.trip_id,
                userId: split.userId,
                amount: split.amount,
                currencyCode: split.currencyCode,
                isAccepted: split.isAccepted,
                createdAt: split.createdAt,
                updatedAt: split.updatedAt
            )
        }
        return (inserted.asModel, persistedSplits)
    }

    /// Updates an expense and replaces its splits atomically from the iOS side
    /// (delete-then-insert because PostgREST has no native "replace splits"
    /// primitive). RLS still gates each operation.
    ///
    /// Pass `previousPersistedRow` with the row **before** this edit so
    /// ``BudgetLedgerNormalizationPolicy`` can reuse the locked FX multiplier
    /// when only amount / title / splits change (same original ISO + same
    /// expense calendar day). Omit for inserts or when unknown.
    func updateExpense(
        _ userEntry: TripExpense,
        splits: [ExpenseSplit],
        tripBudgetCurrency: String,
        previousPersistedRow: TripExpense? = nil
    ) async throws {
        guard let client else { throw SupabaseManagerError.notConfigured }
        let normalized = try await Self.normalizeUserExpenseForTripLedger(
            userEntry: userEntry,
            splits: splits,
            tripBudgetCurrency: tripBudgetCurrency,
            previousPersistedRow: previousPersistedRow
        )
        let ledger = normalized.ledger
        let ledgerSplits = normalized.splits

        let payload = TripExpenseUpdate(
            payer_user_id: ledger.payerUserId,
            booking_id: ledger.bookingId,
            title: ledger.title,
            amount: DecimalCodec(ledger.amount),
            currency: ledger.currencyCode,
            original_currency: ledger.originalCurrencyCode,
            original_amount: DecimalCodec(ledger.originalAmount),
            fx_rate_at_capture: DecimalCodec(ledger.fxRateAtCapture),
            fx_rate_date: ExpenseDateFormatter.string(from: ledger.fxRateDate),
            category: ledger.category.rawValue,
            split_type: ledger.splitType.rawValue,
            expense_date: ExpenseDateFormatter.string(from: ledger.expenseDate),
            notes: ledger.notes
        )
        try await client
            .from("trip_expenses")
            .update(payload)
            .eq("id", value: ledger.id.uuidString.lowercased())
            .execute()

        try await client
            .from("expense_splits")
            .delete()
            .eq("expense_id", value: ledger.id.uuidString.lowercased())
            .execute()

        if !ledgerSplits.isEmpty {
            let splitInserts = ledgerSplits.map { split in
                ExpenseSplitInsert(
                    expense_id: ledger.id,
                    trip_id: ledger.tripId,
                    user_id: split.userId,
                    amount: DecimalCodec(split.amount),
                    currency: split.currencyCode,
                    is_accepted: split.isAccepted
                )
            }
            try await client
                .from("expense_splits")
                .insert(splitInserts)
                .execute()
        }
    }

    private struct NormalizedLedgerPack {
        let ledger: TripExpense
        let splits: [ExpenseSplit]
    }

    /// Maps the composer’s row (user currency) onto trip-budget ledger currency
    /// and re-denominates splits so balances stay consistent with `amount`.
    private static func normalizeUserExpenseForTripLedger(
        userEntry: TripExpense,
        splits: [ExpenseSplit],
        tripBudgetCurrency: String,
        previousPersistedRow: TripExpense? = nil
    ) async throws -> NormalizedLedgerPack {
        let tripCode = BudgetCurrencyProductPolicy.normalizedTripBudgetCurrencyCode(tripBudgetCurrency)
        let origCode = PreferredCurrencyFormatting.normalizeInput(userEntry.currencyCode) ?? tripCode
        let originalAmount = userEntry.amount

        let tripAmount: Decimal
        let fxRate: Decimal
        let fxDate: Date

        if origCode == tripCode {
            tripAmount = TripExpenseLedgerNormalizer.roundMoney2(originalAmount)
            fxRate = 1
            fxDate = userEntry.expenseDate
        } else if let previous = previousPersistedRow,
                  previous.fxRateAtCapture > 0,
                  BudgetLedgerNormalizationPolicy.shouldPreserveLockedFxQuoteOnManualExpenseUpdate(
                    persistedRow: previous,
                    composerEntry: userEntry,
                    tripBudgetCurrency: tripBudgetCurrency
                  ) {
            tripAmount = TripExpenseLedgerNormalizer.roundMoney2(
                originalAmount * previous.fxRateAtCapture
            )
            fxRate = previous.fxRateAtCapture
            fxDate = previous.fxRateDate
        } else {
            guard let quote = await CurrencyService.shared.convert(
                amount: 1,
                from: origCode,
                to: tripCode,
                on: userEntry.expenseDate
            ) else {
                let ref = BudgetFxQuoteSupport.makeReference()
                BudgetFxTelemetry.recordSaveBlocked(
                    supportReference: ref,
                    base: origCode,
                    quoteDate: ExpenseDateFormatter.string(from: userEntry.expenseDate),
                    symbolsCount: 1
                )
                throw BudgetExpenseWriteError.fxUnavailable(supportReference: ref)
            }
            let converted = TripExpenseLedgerNormalizer.tripLedgerAmount(
                originalAmount: originalAmount,
                originalCurrencyUppercased: origCode,
                tripBudgetCurrencyUppercased: tripCode,
                tripUnitsPerOneOriginal: quote.amount
            )
            tripAmount = converted.tripAmount
            fxRate = converted.fxRate
            fxDate = ExpenseDateFormatter.parse(quote.snapshot.date) ?? userEntry.expenseDate
        }

        let tripSplits = TripExpenseLedgerNormalizer.convertSplitsToTripCurrency(
            splits: splits,
            originalExpenseTotal: originalAmount,
            tripExpenseTotal: tripAmount,
            tripCurrencyCode: tripCode
        )

        let ledger = TripExpense(
            id: userEntry.id,
            tripId: userEntry.tripId,
            userId: userEntry.userId,
            payerUserId: userEntry.payerUserId,
            bookingId: userEntry.bookingId,
            title: userEntry.title,
            amount: tripAmount,
            currencyCode: tripCode,
            category: userEntry.category,
            splitType: userEntry.splitType,
            expenseDate: userEntry.expenseDate,
            notes: userEntry.notes,
            isAutoSynced: userEntry.isAutoSynced,
            createdAt: userEntry.createdAt,
            updatedAt: userEntry.updatedAt,
            originalAmount: originalAmount,
            originalCurrencyCode: origCode,
            fxRateAtCapture: fxRate,
            fxRateDate: fxDate
        )
        return NormalizedLedgerPack(ledger: ledger, splits: tripSplits)
    }

    /// Deletes an expense (cascades splits via the FK). Returns silently if
    /// RLS swallows the delete — callers should re-fetch to detect.
    func deleteExpense(id: UUID) async throws {
        guard let client else { throw SupabaseManagerError.notConfigured }
        try await client
            .from("trip_expenses")
            .delete()
            .eq("id", value: id.uuidString.lowercased())
            .execute()
    }

    // MARK: - Per-category budgets

    /// Upserts a per-category planned amount. We key by (trip_id, user_id,
    /// category) so the migration's unique constraint deduplicates idempotent
    /// writes; iOS always sends `user_id = auth.uid()` and lets RLS gate it.
    func upsertCategoryBudget(
        tripId: UUID,
        category: ExpenseCategory,
        plannedAmount: Decimal,
        currency: String
    ) async throws {
        guard let client else { throw SupabaseManagerError.notConfigured }
        guard let userId = try? await client.auth.session.user.id else {
            throw SupabaseManagerError.notAuthenticated
        }
        let payload = TripBudgetUpsert(
            trip_id: tripId,
            user_id: userId,
            category: category.rawValue,
            planned_amount: DecimalCodec(plannedAmount),
            currency: currency
        )
        try await client
            .from("trip_budgets")
            .upsert(payload, onConflict: "trip_id,user_id,category")
            .execute()
    }

    /// Deletes a per-category budget. The UI exposes this as "remove cap".
    func deleteCategoryBudget(id: UUID) async throws {
        guard let client else { throw SupabaseManagerError.notConfigured }
        try await client
            .from("trip_budgets")
            .delete()
            .eq("id", value: id.uuidString.lowercased())
            .execute()
    }

    // MARK: - Settlements

    /// Records a "Settle Up" intent. The recipient sees the row in their
    /// settlements list; either party can flip `is_settled` once payment has
    /// completed (we surface that as a separate `markSettled` call so the
    /// payload is small + rate-limited).
    @discardableResult
    func addSettlement(_ settlement: ExpenseSettlement) async throws -> ExpenseSettlement {
        guard let client else { throw SupabaseManagerError.notConfigured }
        let payload = ExpenseSettlementInsert(
            id: settlement.id,
            trip_id: settlement.tripId,
            from_user_id: settlement.fromUserId,
            to_user_id: settlement.toUserId,
            amount: DecimalCodec(settlement.amount),
            currency: settlement.currencyCode,
            is_settled: settlement.isSettled,
            settled_at: settlement.settledAt.map(ExpenseDateFormatter.timestampString),
            settled_via: settlement.settledVia?.rawValue,
            notes: settlement.notes
        )
        let inserted: ExpenseSettlementRow = try await client
            .from("expense_settlements")
            .insert(payload, returning: .representation)
            .select()
            .single()
            .execute()
            .value
        return inserted.asModel
    }

    /// Marks an existing settlement as completed. Uses `now()` server-side via
    /// the column default so clocks stay consistent across devices.
    func markSettled(id: UUID, method: ExpenseSettlement.SettlementMethod) async throws {
        guard let client else { throw SupabaseManagerError.notConfigured }
        let payload = ExpenseSettlementMark(
            is_settled: true,
            settled_at: ExpenseDateFormatter.timestampString(from: Date()),
            settled_via: method.rawValue
        )
        try await client
            .from("expense_settlements")
            .update(payload)
            .eq("id", value: id.uuidString.lowercased())
            .execute()
    }
}

// MARK: - Snapshot value type

/// Aggregate of every budget-shaped row for one trip. The view-model derives
/// rollups + settlements from this snapshot and never asks the network for
/// individual rows in isolation.
struct BudgetSnapshot: Sendable, Hashable {
    var expenses: [TripExpense]
    var splits: [ExpenseSplit]
    var budgets: [TripBudget]
    var settlements: [ExpenseSettlement]

    static let empty = BudgetSnapshot(expenses: [], splits: [], budgets: [], settlements: [])
}

// MARK: - Insert / Update DTOs

private struct TripTotalBudgetUpdate: Encodable, Sendable {
    let total_budget: DecimalCodec?
    let budget_currency: String
}

private struct TripExpenseInsert: Encodable, Sendable {
    let id: UUID
    let trip_id: UUID
    let user_id: UUID
    let payer_user_id: UUID
    let booking_id: UUID?
    let title: String
    let amount: DecimalCodec
    let currency: String
    let original_currency: String
    let original_amount: DecimalCodec
    let fx_rate_at_capture: DecimalCodec
    let fx_rate_date: String
    let category: String
    let split_type: String
    let expense_date: String
    let notes: String?
    let is_auto_synced: Bool
}

private struct TripExpenseUpdate: Encodable, Sendable {
    let payer_user_id: UUID?
    let booking_id: UUID?
    let title: String
    let amount: DecimalCodec
    let currency: String
    let original_currency: String
    let original_amount: DecimalCodec
    let fx_rate_at_capture: DecimalCodec
    let fx_rate_date: String
    let category: String
    let split_type: String
    let expense_date: String
    let notes: String?
}

private struct ExpenseSplitInsert: Encodable, Sendable {
    let expense_id: UUID
    let trip_id: UUID
    let user_id: UUID
    let amount: DecimalCodec
    let currency: String
    let is_accepted: Bool
}

private struct TripBudgetUpsert: Encodable, Sendable {
    let trip_id: UUID
    let user_id: UUID
    let category: String
    let planned_amount: DecimalCodec
    let currency: String
}

private struct ExpenseSettlementInsert: Encodable, Sendable {
    let id: UUID
    let trip_id: UUID
    let from_user_id: UUID
    let to_user_id: UUID
    let amount: DecimalCodec
    let currency: String
    let is_settled: Bool
    let settled_at: String?
    let settled_via: String?
    let notes: String?
}

private struct ExpenseSettlementMark: Encodable, Sendable {
    let is_settled: Bool
    let settled_at: String
    let settled_via: String
}

// MARK: - Wire DTOs (decode)

private struct TripExpenseRow: Decodable, Sendable {
    let id: UUID
    let trip_id: UUID
    let user_id: UUID?
    let payer_user_id: UUID?
    let booking_id: UUID?
    let title: String
    let amount: DecimalCodec
    let currency: String
    let original_currency: String?
    let original_amount: DecimalCodec?
    let fx_rate_at_capture: DecimalCodec?
    let fx_rate_date: String?
    let category: String
    let split_type: String?
    let expense_date: String?
    let notes: String?
    let is_auto_synced: Bool?
    let created_at: String?
    let updated_at: String?

    var asModel: TripExpense {
        let expenseDay = ExpenseDateFormatter.parse(expense_date) ?? Date()
        let origAmt = original_amount?.value ?? amount.value
        let origCur = original_currency ?? currency
        let fx = fx_rate_at_capture?.value ?? 1
        let fxDay = ExpenseDateFormatter.parse(fx_rate_date) ?? expenseDay
        return TripExpense(
            id: id,
            tripId: trip_id,
            userId: user_id,
            payerUserId: payer_user_id ?? user_id,
            bookingId: booking_id,
            title: title,
            amount: amount.value,
            currencyCode: currency,
            category: ExpenseCategory.from(rawValue: category),
            splitType: TripExpense.SplitType.from(rawValue: split_type),
            expenseDate: expenseDay,
            notes: notes,
            isAutoSynced: is_auto_synced ?? false,
            createdAt: SupabaseModelMapping.parsePostgresTimestamp(created_at),
            updatedAt: SupabaseModelMapping.parsePostgresTimestamp(updated_at),
            originalAmount: origAmt,
            originalCurrencyCode: origCur,
            fxRateAtCapture: fx,
            fxRateDate: fxDay
        )
    }
}

private struct ExpenseSplitRow: Decodable, Sendable {
    let id: UUID
    let expense_id: UUID
    let trip_id: UUID
    let user_id: UUID
    let amount: DecimalCodec
    let currency: String
    let is_accepted: Bool?
    let created_at: String?
    let updated_at: String?

    var asModel: ExpenseSplit {
        ExpenseSplit(
            id: id,
            expenseId: expense_id,
            tripId: trip_id,
            userId: user_id,
            amount: amount.value,
            currencyCode: currency,
            isAccepted: is_accepted ?? true,
            createdAt: SupabaseModelMapping.parsePostgresTimestamp(created_at),
            updatedAt: SupabaseModelMapping.parsePostgresTimestamp(updated_at)
        )
    }
}

private struct TripBudgetRow: Decodable, Sendable {
    let id: UUID
    let trip_id: UUID
    let user_id: UUID
    let category: String
    let planned_amount: DecimalCodec
    let currency: String
    let created_at: String?
    let updated_at: String?

    var asModel: TripBudget {
        TripBudget(
            id: id,
            tripId: trip_id,
            userId: user_id,
            category: ExpenseCategory.from(rawValue: category),
            plannedAmount: planned_amount.value,
            currencyCode: currency,
            createdAt: SupabaseModelMapping.parsePostgresTimestamp(created_at),
            updatedAt: SupabaseModelMapping.parsePostgresTimestamp(updated_at)
        )
    }
}

private struct ExpenseSettlementRow: Decodable, Sendable {
    let id: UUID
    let trip_id: UUID
    let from_user_id: UUID
    let to_user_id: UUID
    let amount: DecimalCodec
    let currency: String
    let is_settled: Bool?
    let settled_at: String?
    let settled_via: String?
    let notes: String?
    let created_at: String?
    let updated_at: String?

    var asModel: ExpenseSettlement {
        ExpenseSettlement(
            id: id,
            tripId: trip_id,
            fromUserId: from_user_id,
            toUserId: to_user_id,
            amount: amount.value,
            currencyCode: currency,
            isSettled: is_settled ?? false,
            settledAt: SupabaseModelMapping.parsePostgresTimestamp(settled_at),
            settledVia: ExpenseSettlement.SettlementMethod.from(rawValue: settled_via),
            notes: notes,
            createdAt: SupabaseModelMapping.parsePostgresTimestamp(created_at),
            updatedAt: SupabaseModelMapping.parsePostgresTimestamp(updated_at)
        )
    }
}

// MARK: - Date helpers

/// Single source of truth for `expense_date` (date-only column) and timestamp
/// fields. `expense_date` is stored without a time component in the DB; using
/// the calendar in the local timezone keeps "today" stable across devices.
enum ExpenseDateFormatter {
    private static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let isoTimestamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func string(from date: Date) -> String {
        dateOnly.string(from: date)
    }

    static func timestampString(from date: Date) -> String {
        isoTimestamp.string(from: date)
    }

    static func parse(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if let date = dateOnly.date(from: String(raw.prefix(10))) {
            return date
        }
        return SupabaseModelMapping.parsePostgresTimestamp(raw)
    }
}


// =============================================================================
