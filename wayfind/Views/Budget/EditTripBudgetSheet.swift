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
                VStack(alignment: .leading, spacing: AppSpacing.xl) {
                    BudgetMapSectionCard(title: "Trip Budget") {
                        BudgetMapAmountRow(
                            icon: "wallet.pass.fill",
                            title: "Total Budget",
                            caption: "Set a shared trip cap everyone can track",
                            accent: AppColors.appPrimary,
                            amountText: $amountText,
                            currency: $currency
                        )
                    }

                    if trip.totalBudget != nil {
                        Button(role: .destructive) {
                            Task { await clear() }
                        } label: {
                            HStack(spacing: AppSpacing.md) {
                                MapStyleIcon(
                                    systemName: "trash.fill",
                                    size: .small,
                                    accent: AppColors.appError,
                                    accessibilityLabel: "Clear budget"
                                )

                                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                                    Text("Clear Budget")
                                        .font(.appBody)
                                        .foregroundStyle(AppColors.appError)
                                    Text("Remove the trip-level cap")
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

struct BudgetMapSectionCard<Content: View>: View {
    let title: String?
    let content: Content

    init(title: String?, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            if let title {
                FormSectionTitle(title)
            }

            VStack(spacing: 0) {
                content
            }
            .background(AppColors.appSurface)
            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                    .strokeBorder(AppColors.appDivider, lineWidth: 1)
            }
        }
    }
}

struct BudgetMapAmountRow: View {
    let icon: String
    let title: String
    let caption: String
    let accent: Color
    @Binding var amountText: String
    @Binding var currency: String

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            MapStyleIcon(
                systemName: icon,
                size: .small,
                accent: accent,
                accessibilityLabel: title
            )

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(title)
                    .font(.appBody)
                    .foregroundStyle(AppColors.textPrimary)
                Text(caption)
                    .font(.appSmall)
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: AppSpacing.md)

            TextField("0", text: $amountText)
                .font(.appBody)
                .foregroundStyle(AppColors.textPrimary)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .onChange(of: amountText) { _, newValue in
                    amountText = MoneyField.sanitize(newValue)
                }
                .frame(minWidth: BudgetMapFormMetrics.amountFieldMinWidth)

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
        .padding(.horizontal, AppSpacing.md)
        .frame(minHeight: BudgetMapFormMetrics.tallRowMinHeight)
        .contentShape(Rectangle())
    }
}

enum BudgetMapFormMetrics {
    static let rowMinHeight: CGFloat = 56
    static let tallRowMinHeight: CGFloat = 64
    static let amountFieldMinWidth: CGFloat = 72
}


// =============================================================================
