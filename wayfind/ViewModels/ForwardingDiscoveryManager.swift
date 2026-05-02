//
//  ForwardingDiscoveryManager.swift
//  wayfind
//
//  Created by Ashish Jambhulkar on 4/2/26.
//

import Foundation
import Observation

@Observable
@MainActor
final class ForwardingDiscoveryManager {
    private let userDefaultsKey = "dismissed_forwarding_trips"

    var firstBookingEverParsed: Bool {
        get { UserDefaults.standard.bool(forKey: "first_booking_parsed") }
        set { UserDefaults.standard.set(newValue, forKey: "first_booking_parsed") }
    }

    func isBannerDismissed(for tripId: UUID) -> Bool {
        dismissedTripIds.contains(tripId.uuidString)
    }

    func dismissBanner(for tripId: UUID) {
        var ids = dismissedTripIds
        ids.insert(tripId.uuidString)
        saveDismissedTripIds(ids)
    }

    func shouldShowTimelineBanner(tripBookingCount: Int, tripId: UUID) -> Bool {
        tripBookingCount == 0 && !isBannerDismissed(for: tripId)
    }

    func shouldShowSpeedDialFooter(totalBookingsAcrossTrips: Int) -> Bool {
        totalBookingsAcrossTrips < 3
    }

    func shouldShowInlineHint(dayBookingCount: Int) -> Bool {
        dayBookingCount == 0
    }

    func shouldShowPillPulseDot(tripBookingCount: Int) -> Bool {
        tripBookingCount == 0
    }

    private var dismissedTripIds: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: userDefaultsKey) ?? [])
    }

    private func saveDismissedTripIds(_ ids: Set<String>) {
        UserDefaults.standard.set(Array(ids), forKey: userDefaultsKey)
    }
}

// =============================================================================

