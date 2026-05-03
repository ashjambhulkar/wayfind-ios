//
//  BudgetExpenseRow.swift
//  wayfind
//
//  Single expense row for the budget hub. Layout: avatar (payer) + category
//  badge + title (with split caption underneath) + amount stack on the right.
//  The amount column shows the gross amount in the row's own currency, with
//  the user's share underneath when it differs (e.g. equal-split with two
//  members where the user paid).
//

import SwiftUI

struct BudgetExpenseRow: View {
    let expense: TripExpense
    /// Trip headline budget ISO (same as `Trip.budgetCurrencyCode`) for pr-2 disclosure.
    let tripBudgetCurrencyCode: String
    let payerName: String?
    let payerAvatarURL: String?
    let myShare: Decimal?

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            ZStack(alignment: .bottomTrailing) {
                avatar
                    .frame(width: 40, height: 40)
                ZStack {
                    Circle()
                        .fill(AppColors.appSurface)
                        .frame(width: 20, height: 20)
                    Image(systemName: expense.category.systemImage)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(expense.category.accentColor)
                }
                .offset(x: 4, y: 4)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(expense.title.isEmpty ? expense.category.displayLabel : expense.title)
                    .font(.appBody.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)
                Text(captionText)
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textTertiary)
                    .lineLimit(1)
            }
            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if expense.isOriginalDistinctFromTripLedger {
                    Text(MoneyFormatter.string(expense.originalAmount, currency: expense.originalCurrencyCode))
                        .font(.appBody.weight(.semibold))
                        .foregroundStyle(AppColors.textPrimary)
                        .monospacedDigit()
                    Text(MoneyFormatter.string(expense.amount, currency: expense.currencyCode))
                        .font(.appSmall)
                        .foregroundStyle(AppColors.textSecondary)
                        .monospacedDigit()
                } else {
                    Text(MoneyFormatter.string(expense.amount, currency: expense.currencyCode))
                        .font(.appBody.weight(.semibold))
                        .foregroundStyle(AppColors.textPrimary)
                        .monospacedDigit()
                }
                if let myShare {
                    let shareTrip = TripExpenseLedgerNormalizer.roundMoney2(myShare)
                    let totalTrip = TripExpenseLedgerNormalizer.roundMoney2(expense.amount)
                    if shareTrip != totalTrip {
                        Text("Your share \(MoneyFormatter.string(myShare, currency: expense.currencyCode))")
                            .font(.appSmall)
                            .foregroundStyle(AppColors.textSecondary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .padding(.vertical, AppSpacing.sm)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var avatar: some View {
        if let urlString = payerAvatarURL, let url = URL(string: urlString) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                avatarFallback
            }
            .clipShape(Circle())
        } else {
            avatarFallback
        }
    }

    private var avatarFallback: some View {
        ZStack {
            Circle().fill(AppColors.appPrimary.opacity(0.2))
            Text(initials)
                .font(.appCaption.weight(.semibold))
                .foregroundStyle(AppColors.appPrimary)
        }
    }

    private var initials: String {
        let source = payerName ?? expense.category.displayLabel
        let words = source.split(separator: " ").prefix(2)
        return words.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    private var captionText: String {
        var pieces: [String] = []
        if let payerName { pieces.append("\(payerName) paid") }
        if expense.isAutoSynced { pieces.append("From booking") }
        if BudgetLedgerNormalizationPolicy.bookingSyncedLedgerDiffersFromTripBudgetCap(
            expense: expense,
            tripBudgetCurrency: tripBudgetCurrencyCode
        ) {
            let cap = BudgetCurrencyProductPolicy.normalizedTripBudgetCurrencyCode(tripBudgetCurrencyCode)
            pieces.append("Not in \(cap) trip total")
        }
        if expense.splitType != .equal {
            pieces.append(expense.splitType.displayLabel)
        }
        return pieces.joined(separator: " · ")
    }

    private var accessibilityLabel: String {
        var label = "\(expense.title.isEmpty ? expense.category.displayLabel : expense.title), "
        if expense.isOriginalDistinctFromTripLedger {
            label += MoneyFormatter.string(expense.originalAmount, currency: expense.originalCurrencyCode)
            label += ", "
            label += MoneyFormatter.string(expense.amount, currency: expense.currencyCode)
        } else {
            label += MoneyFormatter.string(expense.amount, currency: expense.currencyCode)
        }
        if let payerName {
            label += ", paid by \(payerName)"
        }
        return label
    }
}


// =============================================================================

#if DEBUG
#Preview("Expense rows") {
    VStack(spacing: 0) {
        BudgetExpenseRow(
            expense: .preview,
            tripBudgetCurrencyCode: "USD",
            payerName: "Alex Johnson",
            payerAvatarURL: nil,
            myShare: Decimal(160)
        )
        BudgetExpenseRow(
            expense: .preview,
            tripBudgetCurrencyCode: "USD",
            payerName: nil,
            payerAvatarURL: nil,
            myShare: nil
        )
    }
    .padding()
    .background(AppColors.appBackground)
}
#endif
