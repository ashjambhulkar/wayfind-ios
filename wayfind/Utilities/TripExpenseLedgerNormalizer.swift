//
//  TripExpenseLedgerNormalizer.swift
//  wayfind
//
//  Pure math for collaborative budget: map a user-entered expense (original
//  amount + currency) onto the trip's budget currency for `trip_expenses.amount`
//  and for `expense_splits`, using a pre-fetched FX multiplier (original → trip).
//

import Foundation

enum TripExpenseLedgerNormalizer {

    private static let moneyScale: Int = 2
    private static let fxScale: Int = 6

    /// Rounds to `numeric(14,2)` style money.
    static func roundMoney2(_ value: Decimal) -> Decimal {
        var rounded = value
        var output = Decimal()
        NSDecimalRound(&output, &rounded, moneyScale, .plain)
        return output
    }

    /// Rounds FX to `numeric(14,6)`.
    static func roundFx6(_ value: Decimal) -> Decimal {
        var rounded = value
        var output = Decimal()
        NSDecimalRound(&output, &rounded, fxScale, .plain)
        return output
    }

    /// `tripAmount = originalAmount * multiplier` where multiplier is
    /// "trip units per 1 original unit" (from `CurrencyService.convert`).
    static func tripLedgerAmount(
        originalAmount: Decimal,
        originalCurrencyUppercased: String,
        tripBudgetCurrencyUppercased: String,
        tripUnitsPerOneOriginal: Decimal
    ) -> (tripAmount: Decimal, fxRate: Decimal) {
        let origCur = originalCurrencyUppercased.uppercased()
        let tripCur = tripBudgetCurrencyUppercased.uppercased()
        guard originalAmount >= 0 else {
            return (0, 1)
        }
        if origCur == tripCur {
            return (roundMoney2(originalAmount), 1)
        }
        guard tripUnitsPerOneOriginal > 0 else {
            return (roundMoney2(originalAmount), 1)
        }
        let tripRaw = originalAmount * tripUnitsPerOneOriginal
        let tripRounded = roundMoney2(tripRaw)
        let fx: Decimal
        if originalAmount == 0 {
            fx = 1
        } else {
            fx = roundFx6(tripRounded / originalAmount)
        }
        return (tripRounded, fx)
    }

    /// Converts split lines from original expense currency into trip budget
    /// currency, preserving ratios so the parts sum to `tripExpenseTotal`
    /// within one cent (last participant absorbs drift).
    static func convertSplitsToTripCurrency(
        splits: [ExpenseSplit],
        originalExpenseTotal: Decimal,
        tripExpenseTotal: Decimal,
        tripCurrencyCode: String
    ) -> [ExpenseSplit] {
        let tripCode = tripCurrencyCode.uppercased()
        guard originalExpenseTotal > 0, !splits.isEmpty else {
            return splits.map {
                ExpenseSplit(
                    id: $0.id,
                    expenseId: $0.expenseId,
                    tripId: $0.tripId,
                    userId: $0.userId,
                    amount: roundMoney2($0.amount),
                    currencyCode: tripCode,
                    isAccepted: $0.isAccepted,
                    createdAt: $0.createdAt,
                    updatedAt: $0.updatedAt
                )
            }
        }

        var scaled: [Decimal] = splits.map { split in
            let ratio = split.amount / originalExpenseTotal
            return ratio * tripExpenseTotal
        }
        for i in scaled.indices {
            scaled[i] = roundMoney2(scaled[i])
        }
        let sum = scaled.reduce(Decimal(0), +)
        let drift = roundMoney2(tripExpenseTotal - sum)
        if drift != 0, let maxIndex = scaled.indices.max(by: { scaled[$0] < scaled[$1] }) {
            scaled[maxIndex] = roundMoney2(scaled[maxIndex] + drift)
        }

        return zip(splits, scaled).map { split, amount in
            ExpenseSplit(
                id: split.id,
                expenseId: split.expenseId,
                tripId: split.tripId,
                userId: split.userId,
                amount: amount,
                currencyCode: tripCode,
                isAccepted: split.isAccepted,
                createdAt: split.createdAt,
                updatedAt: split.updatedAt
            )
        }
    }
}


// =============================================================================
