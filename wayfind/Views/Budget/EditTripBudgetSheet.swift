//
//  EditTripBudgetSheet.swift
//  wayfind
//
//  Owner-only sheet for setting (or clearing) the trip-level total budget.
//  RLS on `trips` ensures the underlying mutation rejects non-owners; the
//  hub gate hides the entry point so the sheet is never reachable for
//  editors / viewers.
//

import SwiftUI

struct EditTripBudgetSheet: View {
    let trip: Trip
    let viewModel: BudgetViewModel
    /// Called once the mutation completes so the parent can patch its
    /// `Trip` snapshot — the sheet itself doesn't own the trip row.
    let onSaved: ((Decimal?, String) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(ToastManager.self) private var toastManager

    @State private var amountText: String = ""
    @State private var currency: String = "USD"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    Text("Set a top-level cap so everyone on the trip can see how spend tracks against the plan.")
                        .font(.appCaption)
                        .foregroundStyle(AppColors.textSecondary)

                    MoneyField(
                        label: "Total budget",
                        placeholder: "0",
                        amountText: $amountText,
                        currency: $currency
                    )

                    if trip.totalBudget != nil {
                        Button(role: .destructive) {
                            Task { await clear() }
                        } label: {
                            Label("Clear cap", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                                .foregroundStyle(AppColors.appError)
                        }
                        .buttonStyle(.bordered)
                        .tint(AppColors.appError.opacity(0.2))
                    }
                }
                .padding(AppSpacing.lg)
            }
            .navigationTitle("Trip Budget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(parsedAmount == nil)
                }
            }
            .onAppear { seedFromInputs() }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }

    private var parsedAmount: Decimal? {
        MoneyField.parse(amountText)
    }

    private func seedFromInputs() {
        currency = trip.budgetCurrencyCode
        if let total = trip.totalBudget {
            amountText = format(amount: total)
        }
    }

    private func save() async {
        guard let amount = parsedAmount else { return }
        await viewModel.updateTripTotalBudget(totalBudget: amount, currency: currency.uppercased())
        onSaved?(amount, currency.uppercased())
        toastManager.show(ToastData(message: "Budget saved", type: .success))
        dismiss()
    }

    private func clear() async {
        await viewModel.updateTripTotalBudget(totalBudget: nil, currency: currency.uppercased())
        onSaved?(nil, currency.uppercased())
        toastManager.show(ToastData(message: "Budget cleared", type: .success))
        dismiss()
    }

    private func format(amount: Decimal) -> String {
        var rounded = amount
        var output = Decimal()
        NSDecimalRound(&output, &rounded, 2, .plain)
        return "\(output)"
    }
}


// =============================================================================
