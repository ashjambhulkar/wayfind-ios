//
//  BudgetSummaryCard.swift
//  wayfind
//
//  Apple Health-scale headline numeric for the trip budget hub. Renders the
//  total spend prominently with a colour-graded progress bar and a day-pace
//  caption ("$60/day · trip ends in 4 days"). Mixed-currency trips show the
//  user's headline currency only and rely on the separate
//  `MixedCurrencyBanner` to disclose the others.
//

import SwiftUI

struct BudgetSummaryCard: View {
    let spent: Decimal
    let budget: Decimal?
    let currency: String
    let dailyPace: Decimal?
    let daysRemainingCaption: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("Spent so far")
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textSecondary)
                Spacer()
                if let budget {
                    Text(MoneyFormatter.string(budget, currency: currency))
                        .font(.appCaption)
                        .foregroundStyle(AppColors.textSecondary)
                        .accessibilityLabel("Budget cap \(MoneyFormatter.string(budget, currency: currency))")
                }
            }

            Text(MoneyFormatter.headlineString(spent, currency: currency))
                .font(.screenTitle)
                .foregroundStyle(AppColors.textPrimary)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .contentTransition(reduceMotion ? .identity : .numericText())

            if let budget, budget > 0 {
                progressBar(spent: spent, budget: budget)
            }

            if let caption = paceCaption {
                Text(caption)
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textTertiary)
            }
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                .stroke(AppColors.appDivider, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private func progressBar(spent: Decimal, budget: Decimal) -> some View {
        let ratio = NSDecimalNumber(decimal: spent / budget).doubleValue
        let clamped = min(max(ratio, 0), 1.5) // allow visual overshoot up to 150%
        let progressColour = colorForRatio(ratio)
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(AppColors.appDivider)
                Capsule()
                    .fill(progressColour)
                    .frame(width: proxy.size.width * CGFloat(min(clamped, 1.0)))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: clamped)
                if clamped > 1 {
                    Capsule()
                        .stroke(AppColors.appError, lineWidth: 2)
                }
            }
        }
        .frame(height: 10)
    }

    private var paceCaption: String? {
        guard let dailyPace, dailyPace > 0 else { return daysRemainingCaption }
        let pace = MoneyFormatter.string(dailyPace, currency: currency) + "/day"
        if let tail = daysRemainingCaption {
            return "\(pace) · \(tail)"
        }
        return pace
    }

    private func colorForRatio(_ ratio: Double) -> Color {
        switch ratio {
        case ..<0.7: return AppColors.appSuccess
        case ..<0.95: return AppColors.appPrimary
        case ..<1.0: return AppColors.appWarning
        default: return AppColors.appError
        }
    }

    private var accessibilityLabel: String {
        let spentString = MoneyFormatter.string(spent, currency: currency)
        if let budget {
            let budgetString = MoneyFormatter.string(budget, currency: currency)
            return "Spent \(spentString) of \(budgetString) budget"
        }
        return "Spent \(spentString)"
    }
}


// =============================================================================
