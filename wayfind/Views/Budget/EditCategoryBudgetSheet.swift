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
            Form {
                Section {
                    ExpenseCategoryGrid(selection: $category)
                        .listRowInsets(EdgeInsets(
                            top: AppSpacing.sm,
                            leading: AppSpacing.sm,
                            bottom: AppSpacing.sm,
                            trailing: AppSpacing.sm
                        ))
                } header: {
                    Text(String(localized: "Category"))
                }

                Section {
                    categoryAmountRow
                } header: {
                    Text(String(localized: "Category Cap"))
                } footer: {
                    Text(String(localized: "Plan spending for this category."))
                }

                if existing != nil {
                    Section {
                        Button(role: .destructive) {
                            Task { await deleteCap() }
                        } label: {
                            Label(
                                "Remove \(category.displayLabel) Cap",
                                systemImage: "trash.fill"
                            )
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppColors.appBackground)
            .tint(category.accentColor)
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

    private var categoryAmountRow: some View {
        HStack(spacing: AppSpacing.sm) {
            TextField(String(localized: "0"), text: $amountText)
                .keyboardType(.decimalPad)
                .onChange(of: amountText) { _, newValue in
                    amountText = MoneyField.sanitize(newValue)
                }

            Menu {
                ForEach(MoneyField.commonCurrencies, id: \.self) { code in
                    Button(code) { currency = code }
                }
            } label: {
                HStack(spacing: AppSpacing.xs) {
                    Text(currency.uppercased())
                        .font(.appCaption.weight(.semibold))
                        .foregroundStyle(AppColors.textPrimary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.appSmall.weight(.semibold))
                        .foregroundStyle(AppColors.textSecondary)
                }
                .padding(.horizontal, AppSpacing.sm)
                .padding(.vertical, AppSpacing.xs)
                .background(AppColors.appBackground)
                .clipShape(Capsule())
            }
            .accessibilityLabel("Currency: \(currency.uppercased())")
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
