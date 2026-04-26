//
//  ExpenseCategoryGrid.swift
//  wayfind
//
//  2x4 grid that lets the user pick the category for a new (or edited)
//  expense. Shared between AddExpenseSheet and EditCategoryBudgetSheet so
//  the icon + colour vocabulary stays identical to the row badges. Tap
//  selection is single-pick; we update the binding immediately so the
//  parent form can react (e.g. recompute the default split).
//

import SwiftUI

struct ExpenseCategoryGrid: View {
    @Binding var selection: ExpenseCategory

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: AppSpacing.md),
        count: 4
    )

    var body: some View {
        LazyVGrid(columns: columns, spacing: AppSpacing.md) {
            ForEach(ExpenseCategory.allCases) { category in
                tile(for: category)
            }
        }
    }

    @ViewBuilder
    private func tile(for category: ExpenseCategory) -> some View {
        let isSelected = (selection == category)
        Button {
            HapticManager.light()
            selection = category
        } label: {
            VStack(spacing: AppSpacing.xs) {
                ZStack {
                    Circle()
                        .fill(category.accentColor.opacity(isSelected ? 0.25 : 0.12))
                    Image(systemName: category.systemImage)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(category.accentColor)
                }
                .frame(width: 48, height: 48)
                Text(category.displayLabel)
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppSpacing.sm)
            .background(
                RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                    .stroke(
                        isSelected ? category.accentColor : AppColors.appDivider,
                        lineWidth: isSelected ? 2 : 1
                    )
                    .background(
                        RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                            .fill(isSelected ? category.accentColor.opacity(0.06) : Color.clear)
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Category: \(category.displayLabel)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}


// =============================================================================

#if DEBUG
#Preview("Category grid") {
    @Previewable @State var selection: ExpenseCategory = .food
    ExpenseCategoryGrid(selection: $selection)
        .padding()
        .background(AppColors.appBackground)
}
#endif
