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

    var isWishlist: Bool { dayNumber == 0 }
}
