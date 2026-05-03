//
//  BudgetHomeCurrencyHeader.swift
//  wayfind
//
//  Wave 2.2b — auxiliary header surfaced above the budget summary card
//  whenever the trip currency differs from the user's personal display
//  currency (``BudgetCurrencyProductPolicy/personalDisplayCurrencyCode``).
//
//  Behavior (Wave 4.5 — hard gate):
//    • Pro user      → tap to toggle between trip-currency and
//      home-currency display; footer shows rate date + source.
//    • Free user     → toggle is still visible so the value is
//      discoverable, but tapping it presents the paywall through
//      `PaywallPresenter.shared.present(.multiCurrency, …)` instead
//      of switching the display. A small lock chip in the corner
//      hints at the upgrade path so the tap isn't a surprise.
//    • Footer line shows the rate date and the source ("Frankfurter"
//      or "via fallback") so the conversion isn't a black box.
//

import SwiftUI

struct BudgetHomeCurrencyHeader: View {
    let totalAmount: Decimal
    let tripCurrency: String
    /// From `profiles.preferred_currency`; when nil, policy falls back to locale.
    var preferredCurrencyFromProfile: String? = nil

    @Environment(DataService.self) private var dataService

    @AppStorage("wayfind.budget.preferHomeCurrency") private var preferHomeCurrency: Bool = false
    @State private var converted: Decimal?
    @State private var rateDate: String = ""
    @State private var fallbackUsed: Bool = false
    @State private var error: String?

    private var hasPremiumAccess: Bool {
        EntitlementService.shared.hasPremiumAccess
    }

    private var personalDisplayCurrency: String {
        BudgetCurrencyProductPolicy.personalDisplayCurrencyCode(
            preferredFromProfile: preferredCurrencyFromProfile,
            localeCurrencyCode: Locale.current.currency?.identifier
        )
    }

    private var shouldShow: Bool {
        personalDisplayCurrency != tripCurrency.uppercased() && totalAmount > 0
    }

    var body: some View {
        Group {
            if shouldShow {
                content
            } else {
                EmptyView()
            }
        }
        .task(id: "\(totalAmount)|\(tripCurrency)|\(personalDisplayCurrency)|\(preferredCurrencyFromProfile ?? "")") {
            // Wave 4.5 — if a previously-Pro user churned to free
            // we don't want their persisted `preferHomeCurrency=true`
            // to keep silently consuming the converted view. Reset
            // before refreshing so the gate is enforced top-down.
            if !hasPremiumAccess && preferHomeCurrency {
                preferHomeCurrency = false
            }
            await refresh()
        }
    }

    @ViewBuilder
    private var content: some View {
        Button {
            if hasPremiumAccess {
                preferHomeCurrency.toggle()
                Task { await refresh() }
            } else {
                // Wave 4.5 — hard gate. The toggle stays visible so
                // users see the feature; tap routes through the
                // central paywall presenter (which also publishes
                // pro_gate_attempted with the right metadata).
                PaywallPresenter.shared.present(
                    .currencyMulti,
                    dataService: dataService,
                    metadata: [
                        "trip_currency": tripCurrency,
                        "home_currency": personalDisplayCurrency,
                        "trigger": "budget_header_toggle",
                    ]
                )
            }
        } label: {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: "arrow.left.arrow.right.circle")
                    .foregroundStyle(AppColors.appPrimary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(formattedAmount)
                            .font(.appBody.weight(.semibold))
                            .foregroundStyle(AppColors.textPrimary)
                        Text(currentDisplayCurrency)
                            .font(.appCaption)
                            .foregroundStyle(AppColors.textSecondary)
                    }
                    if let line = supportingLine {
                        Text(line)
                            .font(.caption2)
                            .foregroundStyle(AppColors.textTertiary)
                    }
                }
                Spacer()
                if hasPremiumAccess {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppColors.appPrimary)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill")
                            .font(.caption2.weight(.semibold))
                        Text("Pro")
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(AppColors.appPrimary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        AppColors.appPrimary.opacity(0.12),
                        in: Capsule()
                    )
                }
            }
            .padding(AppSpacing.md)
            .background(AppColors.appSurface, in: RoundedRectangle(cornerRadius: AppCornerRadius.medium))
            .overlay(
                RoundedRectangle(cornerRadius: AppCornerRadius.medium)
                    .strokeBorder(AppColors.appDivider, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(hasPremiumAccess
            ? "Switches between trip and preferred display currency."
            : "Wayfind Pro required. Opens upgrade screen.")
    }

    private var currentDisplayCurrency: String {
        preferHomeCurrency ? personalDisplayCurrency : tripCurrency
    }

    private var formattedAmount: String {
        let amount: Decimal
        if preferHomeCurrency, let converted {
            amount = converted
        } else {
            amount = totalAmount
        }
        return MoneyFormatter.string(amount, currency: currentDisplayCurrency)
    }

    private var supportingLine: String? {
        if let error { return error }
        if preferHomeCurrency {
            let suffix = fallbackUsed ? " (backup)" : ""
            if rateDate.isEmpty { return nil }
            return "Rate from \(rateDate)\(suffix)"
        }
        return hasPremiumAccess
            ? "Tap to view in \(personalDisplayCurrency)"
            : "Tap to unlock \(personalDisplayCurrency) view"
    }

    private var accessibilityLabel: String {
        let direction = preferHomeCurrency ? "in your preferred display currency" : "in trip currency"
        return "Total budget \(formattedAmount) \(currentDisplayCurrency) \(direction). Tap to switch."
    }

    private func refresh() async {
        guard preferHomeCurrency else {
            converted = nil
            error = nil
            return
        }
        let result = await CurrencyService.shared.convert(
            amount: totalAmount,
            from: tripCurrency,
            to: personalDisplayCurrency
        )
        if let result {
            converted = result.amount
            rateDate = result.snapshot.date
            fallbackUsed = !result.snapshot.usedFallbackProviders.isEmpty
            error = nil
        } else {
            error = "Couldn't load today's rate. Showing latest cached value."
        }
    }
}
