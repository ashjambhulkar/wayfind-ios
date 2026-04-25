//
//  PaywallPresenter.swift
//  wayfind
//
//  Wave 4.3 — Single source-of-truth for "show the paywall" inside the
//  app. Every gate (CSV export, multi-currency header, flight tracking
//  badge, documents quota, AI day planner cap, manual upgrade tap from
//  Settings) routes through here so:
//
//   1. Analytics stay consistent. The `pro_gate_attempted` event always
//      fires from a single call site with the same `surface` /
//      `metadata` shape. The view that triggered the gate doesn't have
//      to remember to log.
//
//   2. A/B placement ids stay coherent. RevenueCat lets you bind
//      different offerings to different placements (e.g. the AI cap
//      paywall can A/B against a different trial length than the
//      flight-tracking paywall) — see
//      https://www.revenuecat.com/docs/tools/paywalls/displaying-paywalls#presenting-with-placements
//      We keep that mapping in one file so we never accidentally show
//      the wrong offering on a given surface.
//
//   3. Hard vs soft gates behave the same way to the user. Even when
//      Wave 4.5 flips the soft-gate flags off, the *call site* doesn't
//      change — it still calls `PaywallPresenter.shared.present(...)`.
//      The only thing that changes is whether the call is reachable.
//
//  Anti-patterns we explicitly want to avoid (do not "fix" these):
//
//   • Presenting a paywall as a `.fullScreenCover` blocking app launch.
//     Never. Apple App Review will reject it (Guideline 4.5.4) and
//     users perceive it as a wall, not a value prop. We always present
//     a sheet (`.medium` / `.large` detents) on top of working content.
//
//   • Stacking the paywall on top of an existing modal flow. Sheets
//     can chain but the OS animation is jarring and the second sheet
//     covers the context that triggered the upsell. We dismiss the
//     trigger sheet first (where applicable) and present the paywall
//     against the root.
//
//   • Re-presenting the paywall on every app launch when the user has
//     a deferred / Ask-to-Buy purchase pending. Use
//     `EntitlementService.purchasePending` to render an inline
//     "waiting for approval…" state instead.
//
//   • Localising the paywall ourselves. RevenueCat's paywall editor
//     handles localisation server-side, so a price change ships
//     without an app release.
//
//   • Using the paywall to deliver a feature explainer ("here's why
//     Pro is great"). The paywall must close the sale; education
//     belongs upstream in the soft-gate badge / upsell sheet.
//

import Foundation
import Observation
import SwiftUI

#if canImport(RevenueCat)
import RevenueCat
#endif

#if canImport(RevenueCatUI)
import RevenueCatUI
#endif

// MARK: - Placement / surface ids

/// Stable placement ids that RevenueCat's `Offerings.current(for:)`
/// keys off of. Adding a new placement here must also be added to the
/// RevenueCat dashboard (Project → Placements) — otherwise the SDK
/// will silently fall back to the default offering, which defeats the
/// A/B test we'd be trying to set up.
enum PaywallPlacement: String, Sendable {
    /// "X of 3 free remaining" badge tap, configurator hero in the AI
    /// Plan wizard. Free user has at least one credit left.
    case aiBadgeSoftGate = "ai_badge_soft_gate"

    /// AI Plan wizard server returned `free_limit_reached` (HTTP 429).
    /// Free user has burned all credits this month.
    case aiQuotaExhausted = "ai_quota_exhausted"

    /// Budget tab → toolbar → "Export CSV (Pro)".
    case csvExport = "csv_export"

    /// Budget header showing trip currency converted to home currency.
    /// Tapped before purchase.
    case currencyMulti = "currency_multi"

    /// Flight status badge tap on a timeline booking card.
    case flightTracking = "flight_tracking"

    /// Trip documents tab — soft 5/25 ceiling tap.
    case documents = "documents"

    /// Manual entry from Settings → Wayfind Pro tile.
    case settingsManual = "settings_manual"
}

extension PaywallPlacement {
    /// The closed analytics gate this placement maps to. Used so the
    /// `pro_gate_attempted` event reads the same enum the dashboards
    /// already filter on, regardless of which surface triggered it.
    var analyticsGate: ProGate {
        switch self {
        case .aiBadgeSoftGate, .aiQuotaExhausted: return .aiDayPlanner
        case .csvExport: return .csvExport
        case .currencyMulti: return .currencyMulti
        case .flightTracking: return .flightTracking
        case .documents: return .documents
        case .settingsManual: return .aiDayPlanner
        }
    }
}

// MARK: - Presenter

@MainActor
@Observable
final class PaywallPresenter {
    static let shared = PaywallPresenter()

    /// Currently presented paywall context. SwiftUI views observe this
    /// via `@Bindable` and the root scene attaches a `.sheet(item:)`
    /// modifier so the presentation lives off the SwiftUI environment
    /// instead of being scattered across leaf views.
    var pending: PaywallContext?

    private init() {}

    /// Single entry point. Logs the gate attempt, captures the
    /// triggering surface, and surfaces the paywall sheet against the
    /// root scene. Safe to call from any view; the actual presentation
    /// runs at the next render tick.
    func present(
        _ placement: PaywallPlacement,
        dataService: DataService?,
        metadata: [String: String] = [:]
    ) {
        // Fire-and-forget analytics so the UI is never delayed by the
        // RPC round trip. `recordProGateAttempt` already silently fails
        // if Supabase isn't reachable.
        if let dataService {
            Task {
                var enriched = metadata
                enriched["placement"] = placement.rawValue
                enriched["is_pro"] = String(EntitlementService.shared.isPro)
                await dataService.recordProGateAttempt(
                    gate: placement.analyticsGate,
                    surface: placement.rawValue,
                    metadata: enriched
                )
            }
        }

        // If the user is already Pro the paywall is a UX dead-end —
        // route them to the Manage Subscription / CustomerCenter flow
        // instead. Wave 4.6 wires that target; for now we just suppress
        // the present.
        guard !EntitlementService.shared.isPro else { return }

        pending = PaywallContext(placement: placement)
    }

    /// Dismiss the active paywall (used from purchase completion).
    func dismiss() {
        pending = nil
    }
}

/// Identifiable wrapper so SwiftUI's `.sheet(item:)` can drive
/// presentation off `pending`. UUID lets the same placement re-trigger
/// without SwiftUI deciding the sheet hasn't changed.
struct PaywallContext: Identifiable, Equatable {
    let id = UUID()
    let placement: PaywallPlacement
}

// MARK: - SwiftUI host

/// The view actually rendered inside the sheet. Pulls in
/// `RevenueCatUI.PaywallView` when the SDK is installed, falls back to
/// an explainer when it isn't (so dev builds still see a sensible UI
/// and analytics still fire).
struct PaywallHostView: View {
    let context: PaywallContext

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            #if canImport(RevenueCatUI)
            // Wave 4.3 — RevenueCatUI presents the no-code paywall the
            // founder configured in the dashboard. Passing `placement`
            // lets RevenueCat resolve a different offering per surface
            // for A/B tests (default offering still shows when a
            // placement isn't configured server-side, so this is safe
            // to ship before all placements exist).
            //
            // We pass the entitlement id so the SDK auto-dismisses the
            // sheet on a successful purchase that grants `wayfind_pro`,
            // instead of leaving the user staring at a paywall they
            // just successfully completed.
            PaywallView(
                offering: nil,
                fonts: DefaultPaywallFontProvider(),
                displayCloseButton: true
            )
            .onPurchaseCompleted { _ in
                Task {
                    await EntitlementService.shared.refreshCustomerInfo()
                    PaywallPresenter.shared.dismiss()
                }
            }
            .onRestoreCompleted { _ in
                Task {
                    await EntitlementService.shared.refreshCustomerInfo()
                    PaywallPresenter.shared.dismiss()
                }
            }
            #else
            paywallFallback
            #endif
        }
    }

    /// Shown when RevenueCatUI isn't compiled into the build. Keeps
    /// the dev surface honest about what the user *would* see and
    /// gives QA a target to tap so the soft-gate analytics fire end-
    /// to-end without the SDK installed.
    private var paywallFallback: some View {
        VStack(spacing: AppSpacing.lg) {
            ZStack {
                Circle()
                    .fill(AppColors.appPrimaryLight)
                    .frame(width: 64, height: 64)
                Image(systemName: "sparkles")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(AppColors.appPrimary)
            }
            .padding(.top, AppSpacing.lg)

            Text(headline)
                .font(.sectionHeader)
                .foregroundStyle(AppColors.textPrimary)
                .multilineTextAlignment(.center)

            Text(bodyCopy)
                .font(.subheadline)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, AppSpacing.lg)

            Spacer()

            Text("Paywall placeholder — RevenueCatUI not yet linked")
                .font(.caption2)
                .foregroundStyle(AppColors.textTertiary)
                .padding(.bottom, AppSpacing.xs)

            Button {
                PaywallPresenter.shared.dismiss()
                dismiss()
            } label: {
                Text("Maybe later")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.appPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.md)
                    .background(AppColors.appPrimaryLight)
                    .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, AppSpacing.lg)
            .padding(.bottom, AppSpacing.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.appBackground)
    }

    /// Per-placement headline. Each surface earns its own copy so the
    /// paywall feels relevant to what the user just tried to do, not
    /// like a generic "Upgrade now" interruption.
    ///
    /// Localization (cross-cutting): copy is wrapped in
    /// `String(localized:comment:)` so Xcode's automatic extraction
    /// pulls every paywall string into `Localizable.xcstrings` with
    /// the comment as translator context. Translators see *why* the
    /// copy exists, not just the string.
    private var headline: String {
        switch context.placement {
        case .aiBadgeSoftGate, .aiQuotaExhausted:
            return String(
                localized: "Unlimited AI day plans",
                comment: "Paywall headline shown when a free user hits the AI Day Planner limit or taps the credits-remaining badge."
            )
        case .csvExport:
            return String(
                localized: "Export your trip expenses",
                comment: "Paywall headline shown when a free user taps the CSV export action in the Budget toolbar."
            )
        case .currencyMulti:
            return String(
                localized: "See your trip total in your home currency",
                comment: "Paywall headline shown when a free user taps the trip-vs-home currency toggle in the Budget header."
            )
        case .flightTracking:
            return String(
                localized: "Live flight status, even at the gate",
                comment: "Paywall headline shown when a free user taps a locked flight status badge on a timeline booking."
            )
        case .documents:
            return String(
                localized: "Keep every doc with your trip",
                comment: "Paywall headline shown when a free user attempts to upload past the per-trip document cap."
            )
        case .settingsManual:
            return String(
                localized: "Wayfind Pro",
                comment: "Paywall headline shown when a free user taps the Pro tile in the Profile screen — generic upgrade entry, not gated by any specific feature."
            )
        }
    }

    private var bodyCopy: String {
        switch context.placement {
        case .aiBadgeSoftGate, .aiQuotaExhausted:
            return String(
                localized: "Wayfind Pro lifts the 3-plan monthly cap so you can iterate freely on every trip — and unlocks documents, multi-currency totals, CSV export, and live flight tracking.",
                comment: "Paywall body copy for the AI Day Planner placement. References the free monthly cap (3) so changing the cap requires updating this copy too."
            )
        case .csvExport:
            return String(
                localized: "Get a clean CSV of every expense — sortable by date, category, and payer — ready for reimbursement or accounting.",
                comment: "Paywall body copy for the CSV export placement."
            )
        case .currencyMulti:
            return String(
                localized: "We convert each expense at its capture-day rate so totals in your home currency match what you actually spent.",
                comment: "Paywall body copy for the multi-currency placement."
            )
        case .flightTracking:
            return String(
                localized: "Get gate, terminal, and delay updates pushed before the airline app — even with the screen off.",
                comment: "Paywall body copy for the flight tracking placement."
            )
        case .documents:
            return String(
                localized: "Store boarding passes, hotel confirmations, visas, and PDFs alongside your trip — synced across devices.",
                comment: "Paywall body copy for the documents placement."
            )
        case .settingsManual:
            return String(
                localized: "Unlocks unlimited AI day plans, documents, multi-currency totals, CSV export, and live flight tracking.",
                comment: "Paywall body copy for the manual entry from Profile — generic feature laundry list."
            )
        }
    }
}

// MARK: - Scene attachment

extension View {
    /// Attaches the paywall presentation surface to a scene root.
    /// Shouldd be called once at the top of the signed-in scene tree
    /// (currently inside `WayfindApp.body`'s `.signedIn` branch). Every
    /// downstream `PaywallPresenter.shared.present(...)` call routes
    /// to this single sheet.
    ///
    /// We use `.sheet(item:)` instead of `.sheet(isPresented:)` so the
    /// PaywallContext travels with the presentation and the host view
    /// can show per-surface copy.
    @MainActor
    func paywallSurface(presenter: PaywallPresenter = .shared) -> some View {
        modifier(PaywallSurfaceModifier(presenter: presenter))
    }
}

private struct PaywallSurfaceModifier: ViewModifier {
    @Bindable var presenter: PaywallPresenter

    func body(content: Content) -> some View {
        content
            .sheet(item: $presenter.pending) { context in
                NavigationStack {
                    // iPad — the paywall reads as a full-page card
                    // because the sheet adopts a `.large` detent on
                    // regular size class. Phone defaults to `.large`
                    // too so the paywall feels deliberate, not casual.
                    PaywallHostView(context: context)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close") {
                                    PaywallPresenter.shared.dismiss()
                                }
                            }
                        }
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
    }
}
