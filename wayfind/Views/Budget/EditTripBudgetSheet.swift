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
    /// Trip cap ISO when the sheet opened — used for pr-3 currency-change confirmation.
    @State private var baselineTripCapCurrency: String = ""
    @State private var showTripCapCurrencyConfirm = false
    private enum PendingTripBudgetWrite: Equatable {
        case save(Decimal)
        case clear
    }

    @State private var pendingTripBudgetWrite: PendingTripBudgetWrite?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    budgetAmountRow
                } header: {
                    Text(String(localized: "Trip Budget"))
                } footer: {
                    Text(String(localized: "Set a shared trip cap everyone can track."))
                }

                if trip.totalBudget != nil {
                    Section {
                        Button(role: .destructive) {
                            Task { await clear() }
                        } label: {
                            Label("Clear Budget", systemImage: "trash.fill")
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppColors.appBackground)
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
            .onAppear {
                seedFromInputs()
                baselineTripCapCurrency = trip.budgetCurrencyCode
            }
            .confirmationDialog(
                "Change trip budget currency?",
                isPresented: $showTripCapCurrencyConfirm,
                titleVisibility: .visible
            ) {
                Button("Continue") {
                    Task { await executePendingTripBudgetWrite() }
                }
                Button("Cancel", role: .cancel) {
                    pendingTripBudgetWrite = nil
                }
            } message: {
                Text(
                    BudgetLedgerNormalizationPolicy.userFacingTripCapCurrencyChangeConfirmationDetail(
                        previousCapCurrency: baselineTripCapCurrency,
                        nextCapCurrency: currency
                    )
                )
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }

    private var budgetAmountRow: some View {
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
        currency = trip.budgetCurrencyCode
        if let total = trip.totalBudget {
            amountText = format(amount: total)
        }
    }

    private func save() async {
        guard let amount = parsedAmount else { return }
        if BudgetLedgerNormalizationPolicy.shouldConfirmTripCapCurrencyChange(
            previousCapCurrency: baselineTripCapCurrency,
            nextCapCurrency: currency,
            existingExpenseCount: viewModel.snapshot.expenses.count
        ) {
            pendingTripBudgetWrite = .save(amount)
            showTripCapCurrencyConfirm = true
            return
        }
        await persistSave(amount: amount)
    }

    private func clear() async {
        if BudgetLedgerNormalizationPolicy.shouldConfirmTripCapCurrencyChange(
            previousCapCurrency: baselineTripCapCurrency,
            nextCapCurrency: currency,
            existingExpenseCount: viewModel.snapshot.expenses.count
        ) {
            pendingTripBudgetWrite = .clear
            showTripCapCurrencyConfirm = true
            return
        }
        await persistClear()
    }

    private func executePendingTripBudgetWrite() async {
        guard let pending = pendingTripBudgetWrite else { return }
        pendingTripBudgetWrite = nil
        switch pending {
        case .save(let amount):
            await persistSave(amount: amount)
        case .clear:
            await persistClear()
        }
    }

    private func persistSave(amount: Decimal) async {
        await viewModel.updateTripTotalBudget(totalBudget: amount, currency: currency.uppercased())
        onSaved?(amount, currency.uppercased())
        toastManager.show(ToastData(message: "Budget saved", type: .success))
        dismiss()
    }

    private func persistClear() async {
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
