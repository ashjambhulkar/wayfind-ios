//
//  NotificationManager.swift
//  wayfind
//
//  Created by Ashish Jambhulkar on 4/2/26.
//

import Foundation
import UIKit
import UserNotifications

@Observable
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    var isAuthorized = false
    var deviceToken: String?

    /// Phase 5 — set from `WayfindApp` once SwiftUI constructs the
    /// `TabNavigationCoordinator` / `PendingDeepLinkStore` /
    /// `DataService`. We need these to route a notification tap into
    /// the right screen. They're plain weak refs because their
    /// lifetimes are owned by SwiftUI, not us.
    weak var coordinator: TabNavigationCoordinator?
    weak var pendingDeepLinkStore: PendingDeepLinkStore?
    weak var dataService: DataService?

    var hasBeenRequested: Bool {
        get { UserDefaults.standard.bool(forKey: "notification_permission_requested") }
        set { UserDefaults.standard.set(newValue, forKey: "notification_permission_requested") }
    }

    var remindLaterCount: Int {
        get { UserDefaults.standard.integer(forKey: "notification_remind_later_count") }
        set { UserDefaults.standard.set(newValue, forKey: "notification_remind_later_count") }
    }

    var shouldShowPermissionPrompt: Bool {
        !hasBeenRequested && remindLaterCount < 3
    }

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            isAuthorized = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            hasBeenRequested = true
            if isAuthorized {
                await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
            }
            return isAuthorized
        } catch {
            return false
        }
    }

    func registerToken(_ tokenData: Data) {
        deviceToken = tokenData.map { String(format: "%02hhx", $0) }.joined()
    }

    /// Phase 5 — wire references from `WayfindApp` so a notification tap
    /// can navigate. Called whenever the host SwiftUI environment
    /// constructs new state objects (cold start, sign-in, etc.).
    @MainActor
    func attach(
        coordinator: TabNavigationCoordinator,
        pendingDeepLinkStore: PendingDeepLinkStore,
        dataService: DataService
    ) {
        self.coordinator = coordinator
        self.pendingDeepLinkStore = pendingDeepLinkStore
        self.dataService = dataService
    }

    func scheduleTripReminder(trip: Trip) {
        guard isAuthorized else { return }
        let center = UNUserNotificationCenter.current()

        if let dayBefore = Calendar.current.date(byAdding: .day, value: -1, to: trip.startDate) {
            let content = UNMutableNotificationContent()
            content.title = trip.title
            content.body = "Starts tomorrow! Have an amazing trip."
            content.sound = .default

            var components = Calendar.current.dateComponents([.year, .month, .day], from: dayBefore)
            components.hour = 9
            components.minute = 0
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(identifier: "trip-tomorrow-\(trip.id)", content: content, trigger: trigger)
            center.add(request)
        }

        let content = UNMutableNotificationContent()
        content.title = trip.title
        content.body = "Your trip starts today! ✈️"
        content.sound = .default

        var components = Calendar.current.dateComponents([.year, .month, .day], from: trip.startDate)
        components.hour = 8
        components.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: "trip-today-\(trip.id)", content: content, trigger: trigger)
        center.add(request)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Phase 5 — handles user taps on a notification (foreground or
    /// background). Routes through `PushNotificationService` so the
    /// "open trip X" intent is uniformly handled whether we're hot or
    /// cold-launching.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        await MainActor.run {
            guard let dataService else { return }
            PushNotificationService.shared.handleNotificationTap(
                userInfo: userInfo,
                coordinator: coordinator,
                pendingStore: pendingDeepLinkStore,
                dataService: dataService
            )
        }
    }
}


// =============================================================================

