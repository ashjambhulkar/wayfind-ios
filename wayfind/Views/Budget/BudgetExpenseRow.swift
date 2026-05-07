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
                HStack(spacing: AppSpacing.xs) {
                    Text(expense.title.isEmpty ? expense.category.displayLabel : expense.title)
                        .font(.appBody.weight(.semibold))
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(1)
                    provenanceBadge
                }
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

    // MARK: - Provenance badge

    /// Small pill that immediately communicates whether this row was
    /// auto-generated from a booking or entered manually. Visible at a glance
    /// so users understand edit propagation before they tap.
    @ViewBuilder
    private var provenanceBadge: some View {
        if BudgetLedgerNormalizationPolicy.isNeedsAmount(expense) {
            ProvenancePill(
                label: String(localized: "Needs amount"),
                icon: "exclamationmark.circle",
                color: .orange
            )
        } else {
            switch expense.provenance {
            case .bookingLinked:
                ProvenancePill(
                    label: String(localized: "Linked"),
                    icon: "link",
                    color: AppColors.appPrimary
                )
            case .combinedFlight:
                ProvenancePill(
                    label: String(localized: "Combined"),
                    icon: "airplane",
                    color: AppColors.appPrimary
                )
            case .manual:
                EmptyView()
            }
        }
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
        var parts: [String] = []
        parts.append(expense.title.isEmpty ? expense.category.displayLabel : expense.title)
        if expense.isOriginalDistinctFromTripLedger {
            parts.append(MoneyFormatter.string(expense.originalAmount, currency: expense.originalCurrencyCode))
            parts.append(MoneyFormatter.string(expense.amount, currency: expense.currencyCode) + " in trip currency")
        } else {
            parts.append(MoneyFormatter.string(expense.amount, currency: expense.currencyCode))
        }
        if let payerName { parts.append("paid by \(payerName)") }
        if BudgetLedgerNormalizationPolicy.isNeedsAmount(expense) {
            parts.append("needs amount — booking cost was cleared")
        } else {
            switch expense.provenance {
            case .bookingLinked:
                parts.append("linked to booking")
            case .combinedFlight:
                parts.append("combined flight itinerary")
            case .manual:
                break
            }
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Provenance pill

private struct ProvenancePill: View {
    let label: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .semibold))
            Text(label)
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(color.opacity(0.12), in: Capsule())
        .accessibilityHidden(true)
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
