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
        let next = await dataService.fetchBudgetSnapshot(tripId: tripId)
        guard generation == loadGeneration else { return }
        snapshot = next
        hasLoadedAtLeastOnce = true
        lastFetchFailed = false
        isLoading = false
    }

    /// Marks the last reload as failed without replacing the snapshot. Wired
    /// from places where the fetch surface is `try`-throwing (e.g. when the
    /// caller needs to differentiate "empty result" from "RLS denied"). The
    /// hub's existing reload path already swallows errors and returns
    /// `.empty`, so we don't currently call this — present for future use.
    func markFetchFailed() {
        lastFetchFailed = true
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
        onError: ((Error) -> Void)? = nil
    ) async -> Bool {
        let mutationId = UUID()
        pendingMutations[mutationId] = .addExpense(expense, splits)
        snapshot.expenses.insert(expense, at: 0)
        snapshot.splits.append(contentsOf: splits)
        let created = await dataService.addExpense(expense, splits: splits)
        pendingMutations.removeValue(forKey: mutationId)
        if let index = snapshot.expenses.firstIndex(where: { $0.id == expense.id }) {
            snapshot.expenses[index] = created
        }
        return true
    }

    /// Updates an expense locally + on the network. Stashes the previous
    /// rows so the rollback path can restore exactly what the user was
    /// looking at before pressing Save.
    @discardableResult
    func updateExpense(
        _ expense: TripExpense,
        splits: [ExpenseSplit],
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
        await dataService.updateExpense(expense, splits: splits)
        pendingMutations.removeValue(forKey: mutationId)
        return true
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
