//
//  BudgetViewModel.swift
//  wayfind
//
//  @Observable view-model for the trip Budget tab. Owns the budget snapshot
//  for one trip and exposes the derived rollups + simplifier output the UI
//  renders. Mutations go through the optimistic queue so the user sees the
//  row update before the network round-trips, with a rollback path on RLS
//  failure or transient PostgREST error.
//
//  Lifecycle: instantiated by `AppRootTabView` alongside `TripDetailViewModel`
//  and torn down on trip switch. `TripRealtimeService` calls `reload()` on
//  every realtime burst (after a 300ms debounce) so all collaborators converge.
//

import Foundation
import Observation

@Observable
@MainActor
final class BudgetViewModel {
    // MARK: - Dependencies

    private let dataService: DataService
    private(set) var tripId: UUID
    let currentUserId: UUID?

    /// Profile `preferred_currency` (normalized ISO), for budget header conversion.
    private(set) var profilePreferredCurrencyCode: String?

    // MARK: - Snapshot + derived state

    /// Single source of truth — every derived getter reads from here. The
    /// `BudgetSnapshot` value type is replaced wholesale on each reload so
    /// SwiftUI's diffing collapses sub-array updates without flickering.
    private(set) var snapshot: BudgetSnapshot = .empty

    /// `nil` while no fetch has completed yet. Once the first fetch lands —
    /// success or empty — we never flip this back to `nil`, which lets the
    /// hub show "no expenses" instead of a permanent spinner on RLS revoke.
    private(set) var hasLoadedAtLeastOnce = false

    /// True only on the very first fetch. Subsequent reloads (Realtime,
    /// pull-to-refresh) do NOT spin — we keep the existing snapshot visible
    /// underneath. Mirrors `TripDetailViewModel.isLoading`.
    private(set) var isLoading = false

    /// Soft-fail flag: set to `true` when the most recent fetch threw. The UI
    /// renders a small banner ("Couldn't refresh budget · Tap to retry") but
    /// keeps the previous snapshot visible.
    private(set) var lastFetchFailed = false

    /// Generation counter so a slow first fetch can't clobber a fast second
    /// one. Same pattern as `TripDetailViewModel.timelineLoadGeneration`.
    private var loadGeneration = 0

    /// Guards the one-per-session profile currency fetch. `reload()` is called
    /// on every realtime burst AND after each successful mutation
    /// (`addExpense`, `updateExpense`) — the profile currency never changes
    /// during a session, so fetching it more than once is pure waste.
    /// Reset to `false` is intentionally absent: `BudgetViewModel` is torn
    /// down on trip switch, so each new trip always fetches once and caches.
    private var hasFetchedProfileCurrency = false

    /// Deadline before which realtime-triggered reloads are suppressed.
    /// Set after each explicit mutation reload so the realtime echo that
    /// arrives ~300ms later does not fire a redundant second network fetch.
    /// The window (1.5 s) is deliberately longer than the realtime debounce
    /// (300 ms) so any burst of events from a single write is absorbed.
    private var suppressRealtimeReloadUntil: Date?

    /// Optimistic mutation queue. We stash the in-flight mutation under its
    /// own UUID so the rollback path can find it without iterating snapshots.
    /// Empty in the steady state.
    private var pendingMutations: [UUID: PendingMutation] = [:]

    private enum PendingMutation {
        case addExpense(TripExpense, [ExpenseSplit])
        case updateExpense(previous: TripExpense, previousSplits: [ExpenseSplit])
        case deleteExpense(previous: TripExpense, previousSplits: [ExpenseSplit])
        case upsertBudget(previous: TripBudget?)
        case deleteBudget(previous: TripBudget)
        case addSettlement(ExpenseSettlement)
        case markSettled(previous: ExpenseSettlement)
    }

    init(tripId: UUID, currentUserId: UUID?, dataService: DataService) {
        self.tripId = tripId
        self.currentUserId = currentUserId
        self.dataService = dataService
    }

    /// Loads the signed-in user’s preferred display currency for Pro budget header math.
    func refreshPreferredDisplayCurrencyFromProfile() async {
        let detail = await dataService.fetchOwnUserProfileDetail()
        profilePreferredCurrencyCode = detail?.preferredCurrency.flatMap {
            PreferredCurrencyFormatting.normalizeInput($0)
        }
    }

    // MARK: - Reload

    /// Refetches the snapshot from the network (or the mock). Safe to call
    /// from realtime burst handlers; the generation guard ignores stale
    /// responses.
    func reload() async {
        loadGeneration += 1
        let generation = loadGeneration
        if !hasLoadedAtLeastOnce {
            isLoading = true
        }
        guard let next = await dataService.fetchBudgetSnapshotIfAvailable(tripId: tripId) else {
            guard generation == loadGeneration else { return }
            // Critical UX guard: never replace a previously loaded snapshot
            // with `.empty` on transient network/realtime fetch failure.
            lastFetchFailed = true
            isLoading = false
            if !hasLoadedAtLeastOnce {
                // First load failed: still unblock the spinner so the user can retry.
                hasLoadedAtLeastOnce = true
            }
            return
        }
        guard generation == loadGeneration else { return }
        snapshot = next
        hasLoadedAtLeastOnce = true
        lastFetchFailed = false
        isLoading = false
        if !hasFetchedProfileCurrency {
            await refreshPreferredDisplayCurrencyFromProfile()
            hasFetchedProfileCurrency = true
        }
        detectAndReportDuplicateLinkedExpenses(in: next.expenses)
    }

    /// Scans for multiple expense rows sharing the same `bookingId`. This
    /// indicates a dual-writer race pre-migration. Emits telemetry so the
    /// issue shows up in Sentry without crashing the UI.
    private func detectAndReportDuplicateLinkedExpenses(in expenses: [TripExpense]) {
        var bookingGroups: [UUID: [UUID]] = [:]
        for expense in expenses {
            guard let bookingId = expense.bookingId else { continue }
            bookingGroups[bookingId, default: []].append(expense.id)
        }
        for (bookingId, expenseIds) in bookingGroups where expenseIds.count > 1 {
            BudgetFxTelemetry.recordDuplicateLinkedExpense(
                bookingId: bookingId,
                expenseIds: expenseIds
            )
        }
    }

    /// Loads budget data only if no successful fetch has completed yet.
    ///
    /// Use this for eager startup calls where the realtime subscription's
    /// `.subscribed` handler will also fire `reload()` shortly after.
    /// If realtime fires first, `hasLoadedAtLeastOnce` will already be `true`
    /// and this becomes a no-op — no duplicate burst. If realtime is delayed
    /// or never fires (e.g. no connection), this ensures the first paint shows
    /// real data rather than an empty snapshot.
    func reloadIfNeeded() async {
        guard !hasLoadedAtLeastOnce else { return }
        await reload()
    }

    /// Called exclusively by `TripRealtimeService` on incoming budget table
    /// events. Skips the reload if a mutation-driven explicit reload just
    /// completed within the suppress window — avoids the double-fetch that
    /// happens when `addExpense`/`updateExpense` calls `reload()` and the
    /// realtime echo arrives 300 ms later.
    func reloadFromRealtime() async {
        if let suppressedUntil = suppressRealtimeReloadUntil, Date() < suppressedUntil {
            return
        }
        await reload()
    }

    /// Marks the last reload as failed without replacing the snapshot. Wired
    /// from places where the fetch surface is `try`-throwing (e.g. when the
    /// caller needs to differentiate "empty result" from "RLS denied"). The
    /// hub's existing reload path already swallows errors and returns
    /// `.empty`, so we don't currently call this — present for future use.
    func markFetchFailed() {
        lastFetchFailed = true
    }

    // MARK: - Realtime patch apply (event-driven model)

    /// Marks the view-model as loaded from realtime deltas even if we have
    /// not completed a full snapshot fetch yet.
    private func markLoadedFromRealtime() {
        hasLoadedAtLeastOnce = true
        isLoading = false
        lastFetchFailed = false
    }

    func applyRealtimeExpenseUpsert(_ expense: TripExpense) {
        if let index = snapshot.expenses.firstIndex(where: { $0.id == expense.id }) {
            snapshot.expenses[index] = expense
        } else {
            snapshot.expenses.append(expense)
        }
        markLoadedFromRealtime()
    }

    func applyRealtimeExpenseDelete(id: UUID) {
        snapshot.expenses.removeAll { $0.id == id }
        snapshot.splits.removeAll { $0.expenseId == id }
        markLoadedFromRealtime()
    }

    func applyRealtimeSplitUpsert(_ split: ExpenseSplit) {
        if let index = snapshot.splits.firstIndex(where: { $0.id == split.id }) {
            snapshot.splits[index] = split
        } else {
            snapshot.splits.append(split)
        }
        markLoadedFromRealtime()
    }

    func applyRealtimeSplitDelete(id: UUID) {
        snapshot.splits.removeAll { $0.id == id }
        markLoadedFromRealtime()
    }

    func applyRealtimeBudgetUpsert(_ budget: TripBudget) {
        if let index = snapshot.budgets.firstIndex(where: { $0.id == budget.id }) {
            snapshot.budgets[index] = budget
        } else {
            snapshot.budgets.append(budget)
        }
        markLoadedFromRealtime()
    }

    func applyRealtimeBudgetDelete(id: UUID) {
        snapshot.budgets.removeAll { $0.id == id }
        markLoadedFromRealtime()
    }

    func applyRealtimeSettlementUpsert(_ settlement: ExpenseSettlement) {
        if let index = snapshot.settlements.firstIndex(where: { $0.id == settlement.id }) {
            snapshot.settlements[index] = settlement
        } else {
            snapshot.settlements.append(settlement)
        }
        markLoadedFromRealtime()
    }

    func applyRealtimeSettlementDelete(id: UUID) {
        snapshot.settlements.removeAll { $0.id == id }
        markLoadedFromRealtime()
    }

    // MARK: - Derived rollups

    /// Memoised category rollup. Recomputed on every change to `snapshot`;
    /// the underlying `compute` is O(n) and runs in microseconds for a
    /// realistic trip (< 200 expenses).
    var rollup: CategoryRollup {
        CategoryRollup.compute(from: snapshot.expenses)
    }

    /// Per-currency totals across every expense.
    var totalsByCurrency: [String: Decimal] { rollup.totalsByCurrency }

    /// Per-currency, per-category totals.
    var perCategoryByCurrency: [String: [ExpenseCategory: Decimal]] {
        rollup.perCategoryByCurrency
    }

    /// True when the trip has expenses in two or more currencies.
    var isMixedCurrency: Bool { rollup.isMixedCurrency }

    /// "My share" = the sum of accepted splits assigned to me, per currency.
    /// The Mine segment shows this; the All segment shows `totalsByCurrency`.
    var myShareByCurrency: [String: Decimal] {
        guard let userId = currentUserId else { return [:] }
        var totals: [String: Decimal] = [:]
        for split in snapshot.splits where split.userId == userId && split.isAccepted {
            totals[split.currencyCode.uppercased(), default: 0] += split.amount
        }
        return totals
    }

    /// What I personally paid out, per currency. Drives "you've paid" copy.
    var myPaidByCurrency: [String: Decimal] {
        guard let userId = currentUserId else { return [:] }
        var totals: [String: Decimal] = [:]
        for expense in snapshot.expenses where expense.payerUserId == userId {
            totals[expense.currencyCode.uppercased(), default: 0] += expense.amount
        }
        return totals
    }

    /// Net balances by user (positive = owed; negative = owes).
    var balances: [UserBalance] {
        BalanceComputer.compute(snapshot: snapshot)
    }

    /// Min cash-flow simplified settlement suggestions. Drives the
    /// SettlementsSection cards.
    var settlementSuggestions: [SettlementSuggestion] {
        SettlementSimplifier.simplify(balances)
    }

    // MARK: - Mutations (optimistic)

    /// Inserts an expense locally + on the network. On failure the local
    /// mutation rolls back and a warning toast surfaces via the closure.
    @discardableResult
    func addExpense(
        _ expense: TripExpense,
        splits: [ExpenseSplit],
        tripBudgetCurrency: String,
        onError: ((Error) -> Void)? = nil
    ) async -> Bool {
        let mutationId = UUID()
        pendingMutations[mutationId] = .addExpense(expense, splits)
        snapshot.expenses.insert(expense, at: 0)
        snapshot.splits.append(contentsOf: splits)
        do {
            _ = try await dataService.addExpense(
                expense,
                splits: splits,
                tripBudgetCurrency: tripBudgetCurrency
            )
            pendingMutations.removeValue(forKey: mutationId)
            await reload()
            suppressRealtimeReloadUntil = Date().addingTimeInterval(
                BudgetBookingBehaviorPolicy.mutationReloadSuppressWindowSeconds
            )
            return true
        } catch {
            pendingMutations.removeValue(forKey: mutationId)
            snapshot.expenses.removeAll { $0.id == expense.id }
            snapshot.splits.removeAll { $0.expenseId == expense.id }
            onError?(error)
            return false
        }
    }

    /// Updates an expense locally + on the network. Stashes the previous
    /// rows so the rollback path can restore exactly what the user was
    /// looking at before pressing Save.
    @discardableResult
    func updateExpense(
        _ expense: TripExpense,
        splits: [ExpenseSplit],
        tripBudgetCurrency: String,
        onError: ((Error) -> Void)? = nil
    ) async -> Bool {
        guard let previous = snapshot.expenses.first(where: { $0.id == expense.id }) else {
            return false
        }
        let previousSplits = snapshot.splits.filter { $0.expenseId == expense.id }
        let mutationId = UUID()
        pendingMutations[mutationId] = .updateExpense(previous: previous, previousSplits: previousSplits)
        if let index = snapshot.expenses.firstIndex(where: { $0.id == expense.id }) {
            snapshot.expenses[index] = expense
        }
        snapshot.splits.removeAll { $0.expenseId == expense.id }
        snapshot.splits.append(contentsOf: splits)
        do {
            try await dataService.updateExpense(
                expense,
                splits: splits,
                tripBudgetCurrency: tripBudgetCurrency,
                previousPersistedRow: previous
            )
            pendingMutations.removeValue(forKey: mutationId)
            await reload()
            suppressRealtimeReloadUntil = Date().addingTimeInterval(
                BudgetBookingBehaviorPolicy.mutationReloadSuppressWindowSeconds
            )
            return true
        } catch {
            pendingMutations.removeValue(forKey: mutationId)
            if let index = snapshot.expenses.firstIndex(where: { $0.id == previous.id }) {
                snapshot.expenses[index] = previous
            }
            snapshot.splits.removeAll { $0.expenseId == previous.id }
            snapshot.splits.append(contentsOf: previousSplits)
            onError?(error)
            return false
        }
    }

    /// Deletes an expense locally + on the network.
    @discardableResult
    func deleteExpense(id: UUID, onError: ((Error) -> Void)? = nil) async -> Bool {
        guard let previous = snapshot.expenses.first(where: { $0.id == id }) else {
            return false
        }
        let previousSplits = snapshot.splits.filter { $0.expenseId == id }
        let mutationId = UUID()
        pendingMutations[mutationId] = .deleteExpense(previous: previous, previousSplits: previousSplits)
        snapshot.expenses.removeAll { $0.id == id }
        snapshot.splits.removeAll { $0.expenseId == id }
        await dataService.deleteExpense(id: id)
        pendingMutations.removeValue(forKey: mutationId)
        return true
    }

    @discardableResult
    func upsertCategoryBudget(
        category: ExpenseCategory,
        plannedAmount: Decimal,
        currency: String
    ) async -> Bool {
        let previous = snapshot.budgets.first(where: { $0.category == category })
        let mutationId = UUID()
        pendingMutations[mutationId] = .upsertBudget(previous: previous)
        if let previous {
            if let index = snapshot.budgets.firstIndex(where: { $0.id == previous.id }) {
                snapshot.budgets[index] = TripBudget(
                    id: previous.id,
                    tripId: previous.tripId,
                    userId: previous.userId,
                    category: category,
                    plannedAmount: plannedAmount,
                    currencyCode: currency,
                    createdAt: previous.createdAt,
                    updatedAt: Date()
                )
            }
        } else if let userId = currentUserId {
            snapshot.budgets.append(TripBudget(
                id: UUID(),
                tripId: tripId,
                userId: userId,
                category: category,
                plannedAmount: plannedAmount,
                currencyCode: currency,
                createdAt: Date(),
                updatedAt: Date()
            ))
        }
        await dataService.upsertCategoryBudget(
            tripId: tripId,
            category: category,
            plannedAmount: plannedAmount,
            currency: currency
        )
        pendingMutations.removeValue(forKey: mutationId)
        return true
    }

    @discardableResult
    func deleteCategoryBudget(id: UUID, onError: ((Error) -> Void)? = nil) async -> Bool {
        guard let previous = snapshot.budgets.first(where: { $0.id == id }) else {
            return false
        }
        let mutationId = UUID()
        pendingMutations[mutationId] = .deleteBudget(previous: previous)
        snapshot.budgets.removeAll { $0.id == id }
        await dataService.deleteCategoryBudget(id: id)
        pendingMutations.removeValue(forKey: mutationId)
        return true
    }

    /// Updates the trip-level total budget cap. Owner-only — RLS on `trips`
    /// will reject the call from anyone else, and the snapshot mirrors that
    /// outcome by relying on a follow-up reload to repaint the cap.
    func updateTripTotalBudget(totalBudget: Decimal?, currency: String) async {
        await dataService.updateTripTotalBudget(
            tripId: tripId,
            totalBudget: totalBudget,
            currency: currency
        )
    }

    @discardableResult
    func addSettlement(_ settlement: ExpenseSettlement) async -> Bool {
        let mutationId = UUID()
        pendingMutations[mutationId] = .addSettlement(settlement)
        snapshot.settlements.insert(settlement, at: 0)
        let inserted = await dataService.addSettlement(settlement)
        pendingMutations.removeValue(forKey: mutationId)
        if let index = snapshot.settlements.firstIndex(where: { $0.id == settlement.id }) {
            snapshot.settlements[index] = inserted
        }
        return true
    }

    @discardableResult
    func markSettled(id: UUID, method: ExpenseSettlement.SettlementMethod) async -> Bool {
        guard let previous = snapshot.settlements.first(where: { $0.id == id }) else {
            return false
        }
        let mutationId = UUID()
        pendingMutations[mutationId] = .markSettled(previous: previous)
        if let index = snapshot.settlements.firstIndex(where: { $0.id == id }) {
            snapshot.settlements[index] = ExpenseSettlement(
                id: previous.id,
                tripId: previous.tripId,
                fromUserId: previous.fromUserId,
                toUserId: previous.toUserId,
                amount: previous.amount,
                currencyCode: previous.currencyCode,
                isSettled: true,
                settledAt: Date(),
                settledVia: method,
                notes: previous.notes,
                createdAt: previous.createdAt,
                updatedAt: Date()
            )
        }
        await dataService.markSettled(id: id, method: method)
        pendingMutations.removeValue(forKey: mutationId)
        return true
    }
}


// =============================================================================
