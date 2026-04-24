//
//  ParsedBooking.swift
//  wayfind
//
//  Created by Ashish Jambhulkar on 4/2/26.
//

import Foundation

struct ParsedBooking: Identifiable, Codable, Hashable {
    let id: UUID
    var userId: UUID
    var tripId: UUID
    var status: ParsedBookingStatus
    var parsedData: [String: String]?
    var createdAt: Date
}

enum ParsedBookingStatus: String, Codable {
    case pending, parsed, confirmed, failed
}

// =============================================================================

