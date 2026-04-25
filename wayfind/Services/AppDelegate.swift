//
//  AppDelegate.swift
//  wayfind
//
//  Phase 5 — Bridges UIKit's pre-SwiftUI lifecycle into our Swift code.
//  Wired into `WayfindApp` via `@UIApplicationDelegateAdaptor` so the OS
//  invokes `application(_:didFinishLaunchingWithOptions:)` *before* the
//  SwiftUI scene appears. That lets us:
//
//   1. Configure FirebaseApp before anything else queries Messaging.
//   2. Set ourselves as `UNUserNotificationCenter.delegate` and
//      `Messaging.delegate` (delegate ordering matters — Firebase routes
//      tokens through the messaging delegate, not the OS one).
//   3. Capture the launch-from-notification payload off `launchOptions`
//      and seed `PendingDeepLinkStore` so cold-start taps land on the
//      correct trip after the app is up.
//
//  Without the Firebase SDK installed, the FirebaseApp/Messaging branches
//  are compiled out by `#if canImport(FirebaseMessaging)`. The rest of
//  the file (delegate wiring, launch-options parsing, APNs token
//  bridging) still runs so the in-app deep-link routing works during
//  development.
//

import Foundation
import UIKit
import UserNotifications

#if canImport(FirebaseCore)
import FirebaseCore
#endif

#if canImport(FirebaseMessaging)
import FirebaseMessaging
#endif

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Set in `application(_:didFinishLaunchingWithOptions:)` from the
    /// notification launch payload (cold start). `WayfindApp` passes its
    /// `PendingDeepLinkStore` into `seedColdStartLink(into:)` once it's
    /// constructed so we can hand the link over.
    private var coldStartTripId: UUID?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // 1. Firebase must configure first so the Messaging singleton is
        // ready before we set its delegate.
        #if canImport(FirebaseCore)
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
        #endif

        // 2. UN delegate (already set by NotificationManager.init) — but
        // we re-assert here in case the AppDelegate is invoked before
        // the Observable is first read by SwiftUI.
        UNUserNotificationCenter.current().delegate = NotificationManager.shared

        // 3. Messaging delegate. The callback is `MessagingDelegate.messaging(_:didReceiveRegistrationToken:)`
        // which fires on a background queue — we hop to MainActor inside
        // the delegate adapter below.
        #if canImport(FirebaseMessaging)
        Messaging.messaging().delegate = MessagingDelegateAdapter.shared
        #endif

        // 4. Cold-start tap: seed the deep-link buffer if we were
        // launched from a notification tap so the next render of
        // `AppRootTabView` can navigate to the trip.
        if let userInfo = launchOptions?[.remoteNotification] as? [AnyHashable: Any] {
            coldStartTripId = PushNotificationService.extractTripId(from: userInfo)
        }

        return true
    }

    /// Called once `WayfindApp` constructs the `PendingDeepLinkStore`.
    /// Drains any cold-start link captured before SwiftUI was up.
    @MainActor
    func seedColdStartLink(into store: PendingDeepLinkStore) {
        guard let tripId = coldStartTripId else { return }
        coldStartTripId = nil
        store.enqueue(.openTrip(tripId: tripId))
    }

    // MARK: - APNs registration

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        // Hand the raw APNs token to Firebase so it can mint the FCM
        // token. The MessagingDelegate fires after this with the FCM
        // string we actually persist server-side.
        Task { @MainActor in
            PushNotificationService.shared.setAPNSToken(deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Log only — never crash the app over a push registration
        // failure. The user will simply not receive push notifications
        // until the next launch / re-register attempt.
        print("[AppDelegate] APNs registration failed:", error.localizedDescription)
    }
}

// MARK: - Messaging delegate adapter

#if canImport(FirebaseMessaging)
/// Standalone NSObject so `Messaging` can hold a delegate without us
/// having to subclass `Messaging`. Forwards the FCM token to
/// `PushNotificationService` on the main actor.
final class MessagingDelegateAdapter: NSObject, MessagingDelegate {
    static let shared = MessagingDelegateAdapter()

    private override init() { super.init() }

    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let fcmToken else { return }
        // The delegate fires on a background queue per the Firebase docs
        // — every state mutation we do downstream is `@MainActor` so we
        // hop here once.
        Task { @MainActor in
            await PushNotificationService.shared.registerFCMToken(fcmToken)
        }
    }
}
#endif


// =============================================================================
