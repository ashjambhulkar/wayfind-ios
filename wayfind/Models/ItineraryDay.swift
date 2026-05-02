//
//  ItineraryDay.swift
//  wayfind
//
//  Created by Ashish Jambhulkar on 4/2/26.
//

import Foundation

struct ItineraryDay: Identifiable, Codable, Hashable {
    let id: UUID
    var tripId: UUID
    var dayNumber: Int
    var date: Date?
    /// IANA id from `trip_days.timezone` when the server set it (e.g. `Europe/London`).
    var timeZoneIdentifier: String? = nil

    var isWishlist: Bool { dayNumber == 0 }
}

// =============================================================================

