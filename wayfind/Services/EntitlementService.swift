//
//  EntitlementService.swift
//  wayfind
//
//  Wave 4.2 — Single source-of-truth for "is this user Pro?".
//
//  Why this lives in a dedicated service (not directly inside views):
//
//   1. Every gate in the app — CSV export, multi-currency header, flight
//      tracking badge, documents quota, AI day planner cap — needs to ask
//      the same question. A shared `@Observable` lets each gate observe
//      a single mutable surface and re-render without having to plumb
//      RevenueCat's `Purchases.shared` through view trees.
//
//   2. RevenueCat's SDK is added via SwiftPM as part of this same wave.
//      Until the package is actually resolved on a given developer's
//      machine the import will fail. Every RevenueCat call site is
//      wrapped in `#if canImport(RevenueCat)` so this file compiles
//      against either configuration. The SDK-less branch returns `false`
//      everywhere, which is the same answer a fresh user would get post-
//      install — i.e. soft-gates still log analytics, hard-gates still
//      lock content. No surprise unlocks during the install rollout.
//
//   3. Identity. RevenueCat assigns its own anonymous appUserID on first
//      launch. We must `logIn(appUserId:)` with the Supabase `user.id`
//      *as soon as auth flips to signedIn* so every receipt resolves to
//      the right Wayfind user, and again on `logOut()` after sign-out so
//      a shared device doesn't leak entitlement state between accounts.
//      `WayfindApp.onChange(authState:)` calls `bind(userId:)` /
//      `unbind()` here.
//
//   4. AI usage badge. Wave 4.4b drops the free-tier monthly cap from 7
//      to 3, and the AI Plan wizard surfaces "X of 3 free remaining".
//      Rather than have the wizard hit the database itself, we cache the
//      remaining count here so the badge can be read synchronously from
//      any view. The count refreshes after each `generate()` and on
//      `bind(userId:)`.
//
//   5. Deferred / Ask-to-Buy. RevenueCat surfaces a deferred state via
//      `CustomerInfo.entitlements.active` being empty *and* a pending
//      purchase being present on the transaction. We expose this as
//      `purchasePending` so the wizard can show "Waiting for guardian
//      approval…" instead of locking back to the paywall.
//
//  The `pro` entitlement id is `Wayfind Pro` and matches what was
//  configured in App Store Connect / RevenueCat per
//  `docs/wave4-app-store-setup.md`.
//

import Foundation
import Observation
import Supabase
import PostgREST

#if canImport(RevenueCat)
import RevenueCat
#endif

// MARK: - Public surface

/// The single Pro entitlement id. Server-side webhook (`revenuecat-webhook`)
/// also writes this id into `user_subscriptions.is_pro`. Anywhere the app
/// asks "is this Pro?" we route through the singleton below — never read
/// `Purchases.shared` directly from a view.
enum EntitlementID {
    static let pro = "Wayfind Pro"
}

/// AI feature key the server keys monthly usage off of. Mirrors
/// `aiFeature = "ai_day_planner"` inside the `itinerary-ai` Edge Function.
private let aiDayPlannerFeature = "ai_day_planner"

@MainActor
@Observable
final class EntitlementService {

    /// App-wide singleton. Constructed lazily on first read so the
    /// RevenueCat SDK is configured *before* anyone calls `.shared`
    /// (configuration happens inside `AppDelegate.didFinishLaunchingWithOptions`).
    static let shared = EntitlementService()

    // MARK: - Observable surface

    /// True iff the active user has the RevenueCat Pro entitlement. Driven
    /// by RevenueCat's `CustomerInfo` when the SDK is present and falls
    /// back to a Supabase `user_subscriptions` poll otherwise. Default
    /// `false` is the safe answer pre-binding — every gate will treat
    /// pre-bind users as Free and log a soft-gate attempt rather than
    /// silently unlock content.
    private(set) var isPro: Bool = false

    /// Server-side cap for free users (Wave 4.4b lowers to 3). We hold
    /// the limit here so the AI wizard's "X of 3 free remaining" badge
    /// doesn't have to hard-code a number that might drift from the
    /// `itinerary-ai` Edge Function constant.
    private(set) var aiFreeMonthlyLimit: Int = 3

    /// Number of AI generations the active user has consumed this calendar
    /// month. Refreshed on `bind`, after every successful `generate()`,
    /// and any time the wizard mounts. Pro users stay at `0` here — the
    /// per-user daily safety cap is enforced server-side, not surfaced.
    private(set) var aiUsedThisMonth: Int = 0

    /// `true` while a RevenueCat purchase is in deferred / Ask-to-Buy
    /// state — guardian approval pending, or Strong Customer
    /// Authentication challenge in flight. The paywall sheet should
    /// stay up showing a "waiting for approval" hint instead of bouncing
    /// the user back to the offering grid.
    private(set) var purchasePending: Bool = false

    /// Mirrors `CustomerInfo.originalAppUserId`. Useful for diagnostic
    /// logging and reconciliation jobs; never use this for gating —
    /// always read `isPro` instead.
    private(set) var revenueCatUserId: String?

    // MARK: - Derived

    /// Convenience for the AI Plan wizard badge. Pro users see "Unlimited";
    /// Free users see "X of 3 free remaining".
    var aiRemainingForFree: Int {
        max(aiFreeMonthlyLimit - aiUsedThisMonth, 0)
    }

    /// `true` iff we should hard-block another generate attempt for a
    /// Free user. Pro returns `false` always. The wizard uses this to
    /// flip the primary CTA into "Upgrade" when the cap is hit, instead
    /// of waiting for the server's 429.
    var aiHardCapReachedForFree: Bool {
        !isPro && aiUsedThisMonth >= aiFreeMonthlyLimit
    }

    // MARK: - Identity

    private var boundUserId: UUID?

    /// Called from `WayfindApp.onChange(authState:)` once the user has a
    /// Supabase session. Maps the Wayfind UUID into RevenueCat so any
    /// purchases made before login (anonymous appUserID) reconcile to
    /// the correct entitlement record server-side. Safe to call again
    /// for the same id — RevenueCat dedupes.
    func bind(userId: UUID) async {
        if boundUserId == userId, isPro { return }
        boundUserId = userId

        #if canImport(RevenueCat)
        do {
            let (info, _) = try await Purchases.shared.logIn(userId.uuidString)
            apply(customerInfo: info)
        } catch {
            // Identity sync failures shouldn't break the app — the user
            // can still browse Free features. They'll get retried on the
            // next app launch / cold start.
            #if DEBUG
            print("[Entitlement] logIn failed:", error.localizedDescription)
            #endif
            await refreshFromBackend(userId: userId)
        }
        #else
        // SDK not installed yet — fall back to the Supabase mirror that
        // `validate-subscription` / `revenuecat-webhook` already write
        // to. This branch is what runs on dev machines that haven't
        // resolved the SwiftPM package yet.
        await refreshFromBackend(userId: userId)
        #endif

        await refreshAIUsage(userId: userId)
    }

    /// Called from `AuthSessionService.signOut()`. Drops RevenueCat back
    /// to an anonymous appUserID so the next account that signs in on
    /// this device starts clean, not inheriting the previous user's
    /// receipt state.
    func unbind() async {
        boundUserId = nil
        isPro = false
        purchasePending = false
        aiUsedThisMonth = 0
        revenueCatUserId = nil

        #if canImport(RevenueCat)
        _ = try? await Purchases.shared.logOut()
        #endif
    }

    // MARK: - Refresh

    /// Pulls the latest `CustomerInfo` from RevenueCat (cached locally,
    /// usually a no-op network call) and re-applies it. Call this from
    /// any view that just returned from a purchase flow so its `isPro`
    /// picks up the new entitlement immediately rather than waiting for
    /// the next `bind`.
    func refreshCustomerInfo() async {
        #if canImport(RevenueCat)
        if let info = try? await Purchases.shared.customerInfo() {
            apply(customerInfo: info)
        }
        #else
        if let id = boundUserId {
            await refreshFromBackend(userId: id)
        }
        #endif
    }

    /// Refreshes the cached AI generation count. The wizard calls this
    /// on appear and after every `generate()` so the badge stays honest
    /// even when multiple devices share the same account.
    func refreshAIUsage() async {
        guard let userId = boundUserId else { return }
        await refreshAIUsage(userId: userId)
    }

    // MARK: - Private — RevenueCat application

    #if canImport(RevenueCat)
    /// Maps a RevenueCat `CustomerInfo` snapshot onto our observable
    /// surface. We treat presence of the configured Pro entitlement key
    /// in `entitlements.active` as the single Pro signal — neither the
    /// product id nor the offering matters here. This keeps the gate
    /// resilient to App Store Connect product renames as long as the
    /// entitlement id stays stable.
    private func apply(customerInfo info: CustomerInfo) {
        isPro = info.entitlements.active[EntitlementID.pro] != nil
        revenueCatUserId = info.originalAppUserId
        purchasePending = info.entitlements.all[EntitlementID.pro]?.willRenew == false
            && info.entitlements.active[EntitlementID.pro] == nil
            && info.nonSubscriptions.isEmpty == false
    }
    #endif

    // MARK: - Private — Supabase mirror fallback

    /// Reads `user_subscriptions.is_pro` for the currently bound user.
    /// This is the path used when the RevenueCat SDK isn't installed
    /// (dev machines mid-rollout) and as a defensive backup when
    /// `Purchases.shared.logIn` fails. The mirror is updated by
    /// `revenuecat-webhook` so it lags real-time entitlement changes
    /// by at most a few seconds.
    private func refreshFromBackend(userId: UUID) async {
        guard let client = AuthSessionService.shared.client else { return }
        struct SubscriptionRow: Decodable {
            let is_pro: Bool
            let expires_at: String?
        }
        do {
            let rows: [SubscriptionRow] = try await client
                .from("user_subscriptions")
                .select("is_pro,expires_at")
                .eq("user_id", value: userId.uuidString)
                .limit(1)
                .execute()
                .value
            if let row = rows.first {
                isPro = row.is_pro
            } else {
                isPro = false
            }
        } catch {
            #if DEBUG
            print("[Entitlement] backend mirror read failed:", error.localizedDescription)
            #endif
        }
    }

    // MARK: - Private — AI usage

    /// Counts `usage_events` rows for the current user / current calendar
    /// month / `ai_day_planner` feature. Mirrors what `claim_ai_usage`
    /// counts server-side so the badge matches the cap the Edge Function
    /// will enforce. Pro users skip the round-trip — the badge isn't
    /// shown for them.
    private func refreshAIUsage(userId: UUID) async {
        guard !isPro else {
            aiUsedThisMonth = 0
            return
        }
        guard let client = AuthSessionService.shared.client else { return }

        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        guard let monthStart = calendar.date(
            from: calendar.dateComponents([.year, .month], from: now)
        ) else { return }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let monthStartIso = formatter.string(from: monthStart)

        struct UsageRow: Decodable {}
        do {
            // PostgREST `count: .exact` returns the row count in a
            // header instead of the body, which is the cheapest way to
            // get a count without paying for transport on N rows.
            let response = try await client
                .from("usage_events")
                .select("id", head: true, count: .exact)
                .eq("user_id", value: userId.uuidString)
                .eq("feature", value: aiDayPlannerFeature)
                .gte("created_at", value: monthStartIso)
                .execute()
            if let count = response.count {
                aiUsedThisMonth = count
            }
        } catch {
            #if DEBUG
            print("[Entitlement] usage refresh failed:", error.localizedDescription)
            #endif
        }
    }
}

// MARK: - Convenience for non-MainActor callers

extension EntitlementService {

    /// Snapshot of the current Pro state, safe to read from any actor.
    /// Used by service-layer code (CSV export, attachment quota checks)
    /// that doesn't want to hop to MainActor purely to read a flag.
    nonisolated var isProSnapshot: Bool {
        get async { await self.isPro }
    }
}
