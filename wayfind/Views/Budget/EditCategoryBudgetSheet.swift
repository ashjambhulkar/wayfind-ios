//
//  EditCategoryBudgetSheet.swift
//  wayfind
//
//  Owner / editor sheet for setting (or clearing) the per-category budget
//  cap. We let either the owner or an editor with `canEditExpenses` set
//  caps because a per-category cap is more "shared planning" than "trip
//  ownership". The trip-level total stays owner-only.
//

import SwiftUI

struct EditCategoryBudgetSheet: View {
    let trip: Trip
    let viewModel: BudgetViewModel
    let initialCategory: ExpenseCategory

    @Environment(\.dismiss) private var dismiss
    @Environment(ToastManager.self) private var toastManager

    @State private var category: ExpenseCategory = .other
    @State private var amountText: String = ""
    @State private var currency: String = "USD"

    private var existing: TripBudget? {
        viewModel.snapshot.budgets.first { $0.category == category }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.xl) {
                    VStack(alignment: .leading, spacing: AppSpacing.sm) {
                        FormSectionTitle("Category")

                        ExpenseCategoryGrid(selection: $category)
                            .padding(AppSpacing.md)
                            .background(AppColors.appSurface)
                            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                                    .strokeBorder(AppColors.appDivider, lineWidth: 1)
                            }
                    }

                    BudgetMapSectionCard(title: "Category Cap") {
                        BudgetMapAmountRow(
                            icon: category.systemImage,
                            title: "\(category.displayLabel) Cap",
                            caption: "Plan spend for this category",
                            accent: category.accentColor,
                            amountText: $amountText,
                            currency: $currency
                        )
                    }

                    if existing != nil {
                        Button(role: .destructive) {
                            Task { await deleteCap() }
                        } label: {
                            HStack(spacing: AppSpacing.md) {
                                MapStyleIcon(
                                    systemName: "trash.fill",
                                    size: .small,
                                    accent: AppColors.appError,
                                    accessibilityLabel: "Remove cap"
                                )

                                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                                    Text("Remove Cap")
                                        .font(.appBody)
                                        .foregroundStyle(AppColors.appError)
                                    Text("Clear the \(category.displayLabel.lowercased()) budget")
                                        .font(.appSmall)
                                        .foregroundStyle(AppColors.textSecondary)
                                }

                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, AppSpacing.md)
                            .frame(minHeight: BudgetMapFormMetrics.rowMinHeight)
                            .background(AppColors.appSurface)
                            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                                    .strokeBorder(AppColors.appDivider, lineWidth: 1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(AppSpacing.lg)
            }
            .navigationTitle("Category Cap")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await saveCap() } }
                        .disabled(parsedAmount == nil || (parsedAmount ?? 0) <= 0)
                }
            }
            .onAppear { seedFromInputs() }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private var parsedAmount: Decimal? {
        MoneyField.parse(amountText)
    }

    private func seedFromInputs() {
        category = initialCategory
        currency = trip.budgetCurrencyCode
        if let existing = existing {
            amountText = format(amount: existing.plannedAmount)
            currency = existing.currencyCode
        } else {
            amountText = ""
        }
    }

    private func saveCap() async {
        guard let amount = parsedAmount else { return }
        let success = await viewModel.upsertCategoryBudget(
            category: category,
            plannedAmount: amount,
            currency: currency.uppercased()
        )
        if success {
            toastManager.show(ToastData(message: "Cap saved", type: .success))
            dismiss()
        }
    }

    private func deleteCap() async {
        guard let existingId = existing?.id else { return }
        let success = await viewModel.deleteCategoryBudget(id: existingId)
        if success {
            toastManager.show(ToastData(message: "Cap removed", type: .success))
            dismiss()
        }
    }

    private func format(amount: Decimal) -> String {
        var rounded = amount
        var output = Decimal()
        NSDecimalRound(&output, &rounded, 2, .plain)
        return "\(output)"
    }
}


// =============================================================================
