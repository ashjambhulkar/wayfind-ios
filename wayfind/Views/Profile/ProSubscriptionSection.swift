//
//  ProSubscriptionSection.swift
//  wayfind
//
//  Wave 4.6 — the "Wayfind Pro" tile on the Profile screen. Single
//  surface for both purchase and self-service so customers never have
//  to email support to manage a subscription they bought from us.
//
//  States:
//    • Pro user                → "You're on Wayfind Pro" status row
//                                 + "Manage subscription" (opens
//                                 RevenueCat CustomerCenter, which we
//                                 customise with Pause / Switch-to-
//                                 monthly anti-churn flows in Wave 4.6).
//                                 + "Restore Purchases" (always shown
//                                 because re-installs without it look
//                                 like Pro got lost).
//    • Free user               → Marketing-style upgrade card
//                                 + "Restore Purchases" CTA (App Store
//                                 review explicitly requires the
//                                 restore button, even on accounts that
//                                 never purchased — bug bounty bait
//                                 otherwise).
//    • RevenueCat unconfigured → Restore button disabled with a
//                                 muted "Subscriptions are unavailable
//                                 in this build" hint, so dev/QA
//                                 builds don't crash on tap.
//
//  Anti-churn (per Wave 4.3 plan): Wayfind never *unsubscribes*
//  through CustomerCenter. We surface Apple's standard cancellation
//  link so the user can complete it through Settings — required by
//  the App Store guidelines — but offer Pause and Switch-to-monthly
//  CustomerCenter buttons as the primary self-service path. The
//  cancellation customisation lives in the RevenueCat dashboard
//  (no-code editor); we just configure here.
//

import SwiftUI

#if canImport(RevenueCat)
import RevenueCat
#endif

#if canImport(RevenueCatUI)
import RevenueCatUI
#endif

struct ProSubscriptionSection: View {
    @Environment(DataService.self) private var dataService

    /// Drives the CustomerCenter sheet when Pro users tap "Manage".
    /// Kept local because there's exactly one entry point and we don't
    /// want to leak RevenueCat-specific state into the global store.
    @State private var showCustomerCenter: Bool = false

    /// Banner copy after a successful or no-op restore. Surfaces on
    /// the Profile screen via a transient `Text` row so users get
    /// confirmation that restore actually ran (silent restores read
    /// as broken).
    @State private var restoreOutcome: RestoreOutcome?

    /// True while the in-progress restore network call is running.
    /// Disables both restore button taps and the "Manage" entry to
    /// avoid double-fires while RevenueCat is in flight.
    @State private var isRestoring: Bool = false

    private var isPro: Bool {
        EntitlementService.shared.isPro
    }

    private var revenueCatConfigured: Bool {
        AppConfig.isRevenueCatConfigured
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("WAYFIND PRO")
                .font(.appSmall)
                .foregroundStyle(AppColors.textTertiary)
                .textCase(.uppercase)
                .tracking(1.5)

            VStack(spacing: 0) {
                if isPro {
                    proStatusRow
                    Divider().background(AppColors.appDivider)
                    manageSubscriptionRow
                } else {
                    upgradeRow
                }

                Divider().background(AppColors.appDivider)
                restoreRow

                if let outcome = restoreOutcome {
                    Divider().background(AppColors.appDivider)
                    outcomeRow(outcome)
                }
            }
            .background(AppColors.appSurface)
            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        }
        .sheet(isPresented: $showCustomerCenter) {
            customerCenterSheet
        }
    }

    // MARK: - Pro state

    private var proStatusRow: some View {
        HStack(spacing: AppSpacing.md) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(AppColors.appSuccess)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("You're on Wayfind Pro")
                    .font(.cardTitle)
                    .foregroundStyle(AppColors.textPrimary)
                Text("Unlimited AI day plans, documents, multi-currency, CSV export, and live flight tracking.")
                    .font(.appSmall)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.md)
        .accessibilityElement(children: .combine)
    }

    private var manageSubscriptionRow: some View {
        Button {
            showCustomerCenter = true
        } label: {
            HStack {
                Text("Manage subscription")
                    .font(.cardTitle)
                    .foregroundStyle(AppColors.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppColors.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.vertical, AppSpacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isRestoring || !revenueCatConfigured)
        .accessibilityLabel("Manage subscription")
        .accessibilityHint("Opens subscription management. Cancel, pause, or switch plans here.")
    }

    // MARK: - Free state

    private var upgradeRow: some View {
        Button {
            // Wave 4.5 — the manual entry routes through the same
            // PaywallPresenter as every gate, so analytics + offering
            // selection match the rest of the app.
            PaywallPresenter.shared.present(
                .settingsManual,
                dataService: dataService,
                metadata: ["trigger": "profile_section"]
            )
        } label: {
            HStack(alignment: .top, spacing: AppSpacing.md) {
                ZStack {
                    Circle()
                        .fill(AppColors.appPrimaryLight)
                        .frame(width: 44, height: 44)
                    Image(systemName: "sparkles")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(AppColors.appPrimary)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Upgrade to Wayfind Pro")
                        .font(.cardTitle)
                        .foregroundStyle(AppColors.textPrimary)
                    Text("Unlimited AI day plans, documents, multi-currency totals, CSV export, and live flight tracking.")
                        .font(.appSmall)
                        .foregroundStyle(AppColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("From $4.99/month • 7-day free trial")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppColors.appPrimary)
                        .padding(.top, 2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppColors.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.vertical, AppSpacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Upgrade to Wayfind Pro. From $4.99 a month, 7-day free trial.")
        .accessibilityHint("Opens the upgrade screen.")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Restore

    private var restoreRow: some View {
        Button {
            Task { await restorePurchases() }
        } label: {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppColors.appPrimary)
                    .accessibilityHidden(true)
                Text("Restore Purchases")
                    .font(.cardTitle)
                    .foregroundStyle(AppColors.textPrimary)
                Spacer()
                if isRestoring {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.vertical, AppSpacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isRestoring || !revenueCatConfigured)
        .accessibilityLabel(isRestoring
            ? "Restoring purchases. Please wait."
            : "Restore Purchases")
        .accessibilityHint(revenueCatConfigured
            ? "Re-syncs purchases made on this Apple ID."
            : "Subscriptions unavailable in this build.")
    }

    private func outcomeRow(_ outcome: RestoreOutcome) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.sm) {
            Image(systemName: outcome.iconName)
                .foregroundStyle(outcome.iconColor)
                .accessibilityHidden(true)
            Text(outcome.message)
                .font(.appSmall)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.md)
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    // MARK: - CustomerCenter

    @ViewBuilder
    private var customerCenterSheet: some View {
        #if canImport(RevenueCatUI)
        // RevenueCatUI's CustomerCenterView reads its anti-churn
        // (Pause / Switch-to-monthly) configuration from the
        // dashboard. We don't override here — the dashboard is the
        // single source of truth for promo offers and exit flows so
        // marketing can iterate without an app release.
        CustomerCenterView()
            .navigationTitle("Manage subscription")
            .navigationBarTitleDisplayMode(.inline)
        #else
        VStack(spacing: AppSpacing.lg) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(AppColors.appPrimary)
                .padding(.top, AppSpacing.xxl)
            Text("Subscription management")
                .font(.sectionHeader)
                .foregroundStyle(AppColors.textPrimary)
            Text("RevenueCatUI isn't linked in this build. In production, this opens the Wayfind subscription manager.")
                .font(.appBody)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppSpacing.lg)
            Spacer()
            Button {
                showCustomerCenter = false
            } label: {
                Text("Close")
                    .font(.appBody.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, AppSpacing.lg)
            .padding(.bottom, AppSpacing.lg)
        }
        .background(AppColors.appBackground)
        #endif
    }

    // MARK: - Actions

    private func restorePurchases() async {
        isRestoring = true
        defer { isRestoring = false }

        // Restore is intentionally NOT logged through
        // `recordProGateAttempt` — it's a recovery action, not a
        // gate trip, and conflating the two would skew the
        // gate-conversion dashboards. If we ever want restore
        // analytics they belong on a separate event/table.

        #if canImport(RevenueCat)
        if !revenueCatConfigured {
            restoreOutcome = .unavailable
            return
        }
        do {
            let info = try await Purchases.shared.restorePurchases()
            await EntitlementService.shared.refreshCustomerInfo()
            // Wave 4.6 — restore is "no purchases found" if the
            // entitlement isn't active. We don't fail the call (the
            // SDK didn't), we just tell the user what happened so
            // they don't think it silently broke.
            let entitlementActive = info.entitlements.active["wayfind_pro"]?.isActive == true
            restoreOutcome = entitlementActive ? .restored : .nothingToRestore
        } catch {
            restoreOutcome = .failed(error.localizedDescription)
        }
        #else
        restoreOutcome = .unavailable
        #endif
    }
}

// MARK: - Outcome

private enum RestoreOutcome: Equatable {
    case restored
    case nothingToRestore
    case failed(String)
    case unavailable

    var message: String {
        switch self {
        case .restored:
            return String(
                localized: "Wayfind Pro restored on this device.",
                comment: "Confirmation banner shown on Profile after a successful Restore Purchases tap that re-enabled the Wayfind Pro entitlement."
            )
        case .nothingToRestore:
            return String(
                localized: "No purchases found on this Apple ID. If you subscribed on another account, sign in with it on the App Store.",
                comment: "Restore Purchases outcome shown when StoreKit returns no active purchases — explicitly tells the user this is not a failure, with remediation."
            )
        case .failed(let detail):
            return String(
                localized: "Couldn't restore purchases. \(detail)",
                comment: "Restore Purchases failure banner. The interpolated value is the localized error description from RevenueCat."
            )
        case .unavailable:
            return String(
                localized: "Subscriptions aren't available in this build. They'll work on TestFlight.",
                comment: "Restore Purchases banner shown in dev/QA builds where RevenueCat isn't configured. Reassures internal testers the production behaviour is intact."
            )
        }
    }

    var iconName: String {
        switch self {
        case .restored: return "checkmark.circle.fill"
        case .nothingToRestore: return "info.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .unavailable: return "wrench.and.screwdriver"
        }
    }

    var iconColor: Color {
        switch self {
        case .restored: return AppColors.appSuccess
        case .nothingToRestore: return AppColors.appPrimary
        case .failed: return AppColors.appError
        case .unavailable: return AppColors.textTertiary
        }
    }
}
