//
//  PushNotificationService.swift
//  wayfind
//
//  Phase 5 — Owns the device's relationship with Firebase Cloud Messaging:
//  storing the FCM token in `public.fcm_tokens`, clearing it on sign-out,
//  and routing notification taps into the in-app navigation stack.
//
//  PREREQS the project must satisfy before the gated path activates:
//    1. Push Notifications target capability (writes `aps-environment`
//       into `Wayfind.entitlements` — already added in this PR).
//    2. Background Modes capability with Remote Notifications (writes
//       `UIBackgroundModes = ['remote-notification']` into the Info plist
//       — already added in this PR).
//    3. APNs `.p8` auth key uploaded to the Firebase Console under Cloud
//       Messaging.
//    4. `GoogleService-Info.plist` added to the bundle.
//    5. SPM dependency `firebase-ios-sdk` (FirebaseCore + FirebaseMessaging
//       products only, no analytics).
//
//  Until prereqs 4+5 land, every call here is a safe no-op so the rest
//  of the app continues to build and run. Once Firebase is wired,
//  `#if canImport(FirebaseMessaging)` flips on automatically.
//
//  Mock backend short-circuit: when `AppConfig.useRealBackend == false`
//  every method bails out before hitting the network.
//

import Foundation
import Observation
import Supabase
import UIKit

#if canImport(FirebaseMessaging)
import FirebaseMessaging
#endif

@Observable @MainActor
final class PushNotificationService {
    static let shared = PushNotificationService()

    /// The most recent FCM token we registered. Cached so `clearTokenForCurrentDevice`
    /// can target the right `(user_id, token)` row instead of nuking every
    /// row for the user — important for users with multiple devices.
    private(set) var lastRegisteredToken: String?

    /// Set when `MessagingDelegate` delivers a token while there is no Supabase
    /// session yet (common on cold start). `resyncFCMTokenAfterAuth()` flushes
    /// this after login because Firebase often does **not** call the delegate
    /// again with the same token.
    private var deferredFCMTokenUntilSession: String?

    /// True once `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`
    /// has fired and we have called `Messaging.messaging().apnsToken = ...`.
    /// Guards any explicit `Messaging.messaging().token` call — Firebase will
    /// refuse with "APNS device token not set" if we request an FCM token before
    /// this point.
    private var hasAPNSToken = false

    private init() {}

    // MARK: - Registration

    /// Upserts `(user_id, token)` into `public.fcm_tokens`. Safe to call
    /// from any actor — internally hops to MainActor for state updates.
    /// Returns silently on mock-mode and on missing client / session.
    func registerFCMToken(_ token: String) async {
        guard AppConfig.useRealBackend else {
            lastRegisteredToken = token
            return
        }
        guard let client = AuthSessionService.shared.client else { return }
        let userId: UUID
        do {
            let session = try await client.auth.session
            userId = session.user.id
        } catch {
            // Not signed in — keep the token so `resyncFCMTokenAfterAuth()` can
            // upsert after `applySession` finishes (delegate may not fire again).
            deferredFCMTokenUntilSession = token
            return
        }
        let row = FCMTokenUpsert(
            userId: userId.uuidString.lowercased(),
            token: token,
            platform: "ios"
        )
        do {
            try await client
                .from("fcm_tokens")
                .upsert(row, onConflict: "user_id,token")
                .execute()
            lastRegisteredToken = token
            deferredFCMTokenUntilSession = nil
        } catch {
            // Don't surface this to the user — push registration is a
            // background concern. Capture only the failure class, never
            // the FCM token itself.
            print("[PushNotificationService] registerFCMToken failed:", error)
            ObservabilityService.capture(
                error: error,
                domain: "push",
                reason: "fcm_token_upsert_failed",
                context: ["platform": "ios"]
            )
        }
    }

    /// Deletes ONLY the single `(user_id, token)` row we last registered.
    /// Critical: do NOT broaden to `delete().eq("user_id", ...)` — that
    /// would log out push for every device the user is signed in on,
    /// which is a privacy + UX bug.
    func clearTokenForCurrentDevice() async {
        let token = lastRegisteredToken
        lastRegisteredToken = nil
        guard AppConfig.useRealBackend else { return }
        guard let token, !token.isEmpty else { return }
        guard let client = AuthSessionService.shared.client else { return }
        let userId: UUID
        do {
            let session = try await client.auth.session
            userId = session.user.id
        } catch {
            return
        }
        do {
            try await client
                .from("fcm_tokens")
                .delete()
                .eq("user_id", value: userId.uuidString.lowercased())
                .eq("token", value: token)
                .execute()
        } catch {
            print("[PushNotificationService] clearTokenForCurrentDevice failed:", error)
            ObservabilityService.capture(
                error: error,
                domain: "push",
                reason: "fcm_token_delete_failed",
                context: ["platform": "ios"]
            )
        }
    }

    /// Called after Supabase session is established (`applySession`). Triggers
    /// APNs registration so the OS hands us a device token (which then lets
    /// Firebase mint an FCM token via `setAPNSToken`). If `hasAPNSToken` is
    /// already true — the token arrived before login — we can also query the
    /// FCM token directly and flush any deferred value.
    func resyncFCMTokenAfterAuth() async {
        guard AppConfig.useRealBackend else { return }

        // Always ask for APNs registration; this is idempotent and ensures the
        // token arrives even if the user bypassed the onboarding permission UI.
        await MainActor.run {
            UIApplication.shared.registerForRemoteNotifications()
        }

        // Only query the FCM token explicitly when we know the APNs token has
        // already been delivered. If it hasn't, `setAPNSToken` will fetch the
        // FCM token as soon as the APNs callback fires.
        guard hasAPNSToken else {
            return
        }

        #if canImport(FirebaseMessaging)
        let fromSDK = await Self.queryFirebaseRegistrationToken()
        let token = fromSDK ?? deferredFCMTokenUntilSession
        guard let token, !token.isEmpty else { return }
        await registerFCMToken(token)
        #else
        if let token = deferredFCMTokenUntilSession, !token.isEmpty {
            await registerFCMToken(token)
        }
        #endif
    }

    // MARK: - Notification tap routing

    /// Handles a notification tap by routing into the app's navigation
    /// stack. Called from `NotificationManager.userNotificationCenter(_:didReceive:)`.
    /// Two paths:
    ///  • If the coordinator is available (app is hot), call
    ///    `coordinator.openTrip(_:)` directly.
    ///  • Otherwise (cold start, signed-out), enqueue into
    ///    `PendingDeepLinkStore` and let `AppRootTabView` drain on next
    ///    render.
    func handleNotificationTap(
        userInfo: [AnyHashable: Any],
        coordinator: TabNavigationCoordinator?,
        pendingStore: PendingDeepLinkStore?,
        dataService: DataService
    ) {
        guard let tripId = Self.extractTripId(from: userInfo) else { return }
        ObservabilityService.breadcrumb(
            "notification_tap",
            category: "notifications",
            context: [
                "has_coordinator": coordinator != nil,
                "trip_id": tripId,
            ]
        )
        if let coordinator {
            Task { @MainActor in
                let trips = await dataService.fetchTrips()
                if let trip = trips.first(where: { $0.id == tripId }) {
                    coordinator.openTrip(trip)
                } else {
                    pendingStore?.enqueue(.openTrip(tripId: tripId))
                }
            }
        } else {
            pendingStore?.enqueue(.openTrip(tripId: tripId))
        }
    }

    /// Pull the trip id out of the FCM `data` payload. The server-side
    /// notification format (defined by the future Edge Function) carries
    /// `trip_id` as a top-level string. We tolerate either casing for
    /// forward-compat with backend rename churn.
    static func extractTripId(from userInfo: [AnyHashable: Any]) -> UUID? {
        let candidates = ["trip_id", "tripId", "tripID"]
        for key in candidates {
            if let raw = userInfo[key] as? String, let id = UUID(uuidString: raw) {
                return id
            }
        }
        return nil
    }

    // MARK: - APNs token bridging

    /// Hands the APNs device token to FirebaseMessaging, marks `hasAPNSToken`,
    /// then immediately fetches the FCM registration token. This is the correct
    /// place to trigger the FCM fetch — Firebase will refuse with "APNS device
    /// token not set" if `Messaging.messaging().token` is called before this.
    nonisolated func setAPNSToken(_ deviceToken: Data) {
        #if canImport(FirebaseMessaging)
        Messaging.messaging().apnsToken = deviceToken

        Messaging.messaging().token { token, error in
            if let error {
                print("[PushNotificationService] Firebase Messaging.token error after APNs set:", error.localizedDescription)
                return
            }
            guard let token, !token.isEmpty else {
                print("[PushNotificationService] Firebase returned nil FCM token after APNs set")
                return
            }
            Task { @MainActor in
                await PushNotificationService.shared.registerFCMToken(token)
                PushNotificationService.shared.hasAPNSToken = true
            }
        }
        #else
        _ = deviceToken
        #endif
    }
}

// MARK: - Wire types

private struct FCMTokenUpsert: Encodable, Sendable {
    let userId: String
    let token: String
    let platform: String

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case token
        case platform
    }
}

#if canImport(FirebaseMessaging)
private extension PushNotificationService {
    /// Async bridge to `Messaging.messaging().token(completion:)` (nonisolated).
    nonisolated static func queryFirebaseRegistrationToken() async -> String? {
        await withCheckedContinuation { continuation in
            Messaging.messaging().token { token, error in
                if let error {
                    print("[PushNotificationService] Firebase Messaging.token error:", error.localizedDescription)
                }
                continuation.resume(returning: token)
            }
        }
    }
}
#endif

// =============================================================================
