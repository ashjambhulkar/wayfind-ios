//
//  CategoryBudgetSection.swift
//  wayfind
//
//  Read-only per-category breakdown for the budget hub. Each row uses the
//  shared `MapStyleIcon` category circles (same as Add Expense / category grid),
//  the planned cap (if any), and an inline progress strip.
//  Only renders categories that either have a planned cap *or* have actual
//  spend — empty categories on a sparse trip stay hidden so the section
//  doesn't read like a long checklist of zeros.
//

import SwiftUI

struct CategoryBudgetSection: View {
    let perCategory: [ExpenseCategory: Decimal]
    let plannedByCategory: [ExpenseCategory: Decimal]
    let currency: String
    let canEdit: Bool
    let onEdit: (ExpenseCategory) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            HStack {
                Text("By Category")
                    .font(.sectionHeader)
                    .foregroundStyle(AppColors.textPrimary)
                Spacer()
                if canEdit {
                    Button {
                        onEdit(.other)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                            .font(.appCaption)
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppColors.appPrimary)
                    .accessibilityLabel("Edit category budgets")
                }
            }

            if visibleCategories.isEmpty {
                Text("No category budgets yet.")
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textTertiary)
            } else {
                VStack(spacing: AppSpacing.md) {
                    ForEach(visibleCategories, id: \.self) { category in
                        CategoryBudgetRow(
                            category: category,
                            spent: perCategory[category] ?? 0,
                            cap: plannedByCategory[category],
                            currency: currency,
                            canEdit: canEdit,
                            onEdit: { onEdit(category) }
                        )
                    }
                }
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
    }

    private var visibleCategories: [ExpenseCategory] {
        ExpenseCategory.allCases.filter { category in
            (perCategory[category] ?? 0) > 0 || (plannedByCategory[category] != nil)
        }
    }
}

private struct CategoryBudgetRow: View {
    let category: ExpenseCategory
    let spent: Decimal
    let cap: Decimal?
    let currency: String
    let canEdit: Bool
    let onEdit: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: { if canEdit { onEdit() } }) {
            HStack(spacing: AppSpacing.md) {
                MapStyleIcon(
                    systemName: category.systemImage,
                    size: .small,
                    accent: category.accentColor,
                    backgroundStyle: .solidAccent,
                    shape: .circle,
                    accessibilityLabel: category.displayLabel
                )

                VStack(alignment: .leading, spacing: AppSpacing.md) {
                    HStack {
                        Text(category.displayLabel)
                            .font(.cardTitle)
                            .foregroundStyle(AppColors.textPrimary)
                        Spacer()
                        Text(MoneyFormatter.string(spent, currency: currency))
                            .font(.appBody.weight(.semibold))
                            .foregroundStyle(AppColors.textPrimary)
                    }
                    progressTrack
                    if let cap {
                        Text("of \(MoneyFormatter.string(cap, currency: currency))")
                            .font(.appCaption)
                            .foregroundStyle(AppColors.textTertiary)
                    }
                }
            }
            .padding(.vertical, AppSpacing.sm)
        }
        .buttonStyle(.plain)
        .disabled(!canEdit)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibility)
        .accessibilityHint(canEdit ? "Double tap to edit cap" : "")
    }

    @ViewBuilder
    private var progressTrack: some View {
        let ratio: Double = {
            guard let cap, cap > 0 else { return 0 }
            return min(max(NSDecimalNumber(decimal: spent / cap).doubleValue, 0), 1.5)
        }()
        let fillColor: Color = ratio >= 1 ? AppColors.appError
            : ratio >= 0.85 ? AppColors.appWarning
            : category.accentColor
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(AppColors.appDivider)
                Capsule()
                    .fill(fillColor)
                    .frame(width: proxy.size.width * CGFloat(min(ratio, 1.0)))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: ratio)
            }
        }
        .frame(height: 6)
    }

    private var accessibility: String {
        let spentString = MoneyFormatter.string(spent, currency: currency)
        if let cap {
            return "\(category.displayLabel): spent \(spentString) of \(MoneyFormatter.string(cap, currency: currency))"
        }
        return "\(category.displayLabel): spent \(spentString)"
    }
}


// =============================================================================
