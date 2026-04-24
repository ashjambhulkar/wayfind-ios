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
}


// =============================================================================

