//
//  CategoryRollup.swift
//  wayfind
//
//  Pure value-typed math used by `BudgetViewModel` to derive everything the
//  UI needs from a `BudgetSnapshot`. Lives outside the view-model so unit
//  tests don't need to spin up a `@MainActor` actor or stub a `DataService`.
//
//  Everything is per-currency: we never collapse mixed currencies into a
//  single "total" because there's no exchange-rate source the user has
//  control over. Mixed-currency trips render a banner instead of a fake
//  conversion.
//

import Foundation

/// Per-currency totals for a single trip. Currency keys are uppercased ISO
/// 4217 codes ("USD", "EUR", …).
struct CategoryRollup: Hashable, Sendable {
    /// `[currency: total]` across every expense (regardless of category).
    var totalsByCurrency: [String: Decimal]
    /// `[currency: [category: total]]` — dictionary order is non-deterministic;
    /// callers should sort by `ExpenseCategory.allCases` for stable rendering.
    var perCategoryByCurrency: [String: [ExpenseCategory: Decimal]]
    /// Set of currencies present anywhere in the snapshot. Used to drive the
    /// "mixed currency" banner without re-walking the expense list.
    var currencies: Set<String>

    static let empty = CategoryRollup(totalsByCurrency: [:], perCategoryByCurrency: [:], currencies: [])

    /// Builds a rollup from raw expenses. O(n) over expenses; caller should
    /// memoise on `BudgetSnapshot` change rather than recomputing per-frame.
    static func compute(from expenses: [TripExpense]) -> CategoryRollup {
        var totals: [String: Decimal] = [:]
        var perCategory: [String: [ExpenseCategory: Decimal]] = [:]
        var currencies: Set<String> = []

        for expense in expenses {
            let code = expense.currencyCode.uppercased()
            currencies.insert(code)
            totals[code, default: 0] += expense.amount
            perCategory[code, default: [:]][expense.category, default: 0] += expense.amount
        }

        return CategoryRollup(
            totalsByCurrency: totals,
            perCategoryByCurrency: perCategory,
            currencies: currencies
        )
    }

    /// Total spend for a currency across every category. Returns 0 when the
    /// currency has no expenses (callers can rely on that for "$0 of $X" UI).
    func total(for currency: String) -> Decimal {
        totalsByCurrency[currency.uppercased()] ?? 0
    }

    /// Spend for a single (currency, category) pair. Returns 0 when missing.
    func amount(for currency: String, category: ExpenseCategory) -> Decimal {
        perCategoryByCurrency[currency.uppercased()]?[category] ?? 0
    }

    /// True when the trip has expenses in two or more distinct currencies.
    /// Drives the mixed-currency banner copy.
    var isMixedCurrency: Bool { currencies.count > 1 }
}

// MARK: - Per-user balances

/// Net position for a single user in a single currency. Positive = the user
/// is owed money; negative = the user owes money. Used as the input to the
/// min-cash-flow simplifier in `SettlementSimplifier`.
struct UserBalance: Hashable, Sendable {
    let userId: UUID
    let currency: String
    let net: Decimal
}

/// Computes each user's net balance per currency from the ledger of expenses,
/// splits, and recorded settlements. The output is the "if everyone paid up
/// right now" snapshot — callers should pass this to `SettlementSimplifier`
/// to get the minimum number of payments required.
///
/// Algorithm:
///   1. Each split is a debit on the split's `userId` (they owe their share).
///   2. Each expense is a credit on the `payerUserId` for the full amount
///      (they fronted the cash).
///   3. Each completed settlement is a credit on `fromUserId` and a debit on
///      `toUserId` (the debt has been paid down, so unwind it).
///
/// We work in `Decimal` throughout. Per-currency keying isolates EUR debts
/// from USD debts so we never accidentally net them.
enum BalanceComputer {
    static func compute(
        snapshot: BudgetSnapshot
    ) -> [UserBalance] {
        // [currency: [userId: net]]
        var balances: [String: [UUID: Decimal]] = [:]

        for split in snapshot.splits where split.isAccepted {
            let code = split.currencyCode.uppercased()
            balances[code, default: [:]][split.userId, default: 0] -= split.amount
        }

        for expense in snapshot.expenses {
            guard let payer = expense.payerUserId else { continue }
            let code = expense.currencyCode.uppercased()
            balances[code, default: [:]][payer, default: 0] += expense.amount
        }

        for settlement in snapshot.settlements where settlement.isSettled {
            let code = settlement.currencyCode.uppercased()
            balances[code, default: [:]][settlement.fromUserId, default: 0] += settlement.amount
            balances[code, default: [:]][settlement.toUserId, default: 0] -= settlement.amount
        }

        var output: [UserBalance] = []
        for (currency, byUser) in balances {
            for (userId, net) in byUser where net != 0 {
                output.append(UserBalance(userId: userId, currency: currency, net: net))
            }
        }
        return output
    }
}

// MARK: - Min cash-flow simplifier

/// One suggested payment between two users. The settlement card UI renders
/// these directly; pressing "Settle Up" creates an `ExpenseSettlement` row
/// with these exact values.
struct SettlementSuggestion: Hashable, Sendable, Identifiable {
    let fromUserId: UUID
    let toUserId: UUID
    let amount: Decimal
    let currency: String

    /// Stable identity for SwiftUI `sheet(item:)` and `ForEach`. Suggestions
    /// are deterministic per (trip, currency, debtor, creditor), so the
    /// composite is unique across a single snapshot.
    var id: String { "\(currency):\(fromUserId.uuidString):\(toUserId.uuidString)" }
}

/// Greedy min-cash-flow algorithm — the same approach Splitwise uses. For
/// each currency independently:
///   1. Bucket users into "owes" (negative) and "owed" (positive).
///   2. Repeatedly match the largest debtor with the largest creditor and
///      transfer `min(|debt|, credit)`.
///   3. Stop when both sides are empty (within an epsilon).
///
/// Worst-case n^2 in user count, but trips have ≤ 25 collaborators so this
/// runs in microseconds. Output is deterministic given a deterministic input
/// thanks to the explicit sort by `userId`.
enum SettlementSimplifier {
    static func simplify(_ balances: [UserBalance]) -> [SettlementSuggestion] {
        var output: [SettlementSuggestion] = []
        let byCurrency = Dictionary(grouping: balances, by: { $0.currency })

        for (currency, perCurrency) in byCurrency {
            var owed = perCurrency
                .filter { $0.net > 0 }
                .sorted { lhs, rhs in
                    if lhs.net == rhs.net { return lhs.userId.uuidString < rhs.userId.uuidString }
                    return lhs.net > rhs.net
                }
                .map { (userId: $0.userId, balance: $0.net) }
            var owes = perCurrency
                .filter { $0.net < 0 }
                .sorted { lhs, rhs in
                    if lhs.net == rhs.net { return lhs.userId.uuidString < rhs.userId.uuidString }
                    return lhs.net < rhs.net
                }
                .map { (userId: $0.userId, balance: -$0.net) }

            let epsilon = Decimal(string: "0.005") ?? 0
            var oi = 0
            var ii = 0
            while oi < owed.count && ii < owes.count {
                let pay = min(owed[oi].balance, owes[ii].balance)
                if pay > epsilon {
                    output.append(SettlementSuggestion(
                        fromUserId: owes[ii].userId,
                        toUserId: owed[oi].userId,
                        amount: pay,
                        currency: currency
                    ))
                }
                owed[oi].balance -= pay
                owes[ii].balance -= pay
                if owed[oi].balance <= epsilon { oi += 1 }
                if owes[ii].balance <= epsilon { ii += 1 }
            }
        }

        return output.sorted { lhs, rhs in
            if lhs.currency != rhs.currency { return lhs.currency < rhs.currency }
            if lhs.fromUserId.uuidString != rhs.fromUserId.uuidString {
                return lhs.fromUserId.uuidString < rhs.fromUserId.uuidString
            }
            return lhs.toUserId.uuidString < rhs.toUserId.uuidString
        }
    }
}


// =============================================================================
