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

struct ForwardedBookingSummary: Equatable, Hashable {
    var pendingCount: Int
    var needsReviewCount: Int
    var importedCount: Int

    static let empty = ForwardedBookingSummary(
        pendingCount: 0,
        needsReviewCount: 0,
        importedCount: 0
    )

    var displayText: String {
        if pendingCount > 0 && needsReviewCount > 0 {
            return "\(pendingCount) pending · \(needsReviewCount) needs review"
        }
        if pendingCount > 0 {
            return pendingCount == 1 ? "1 pending" : "\(pendingCount) pending"
        }
        if needsReviewCount > 0 {
            return needsReviewCount == 1 ? "1 needs review" : "\(needsReviewCount) need review"
        }
        if importedCount > 0 {
            return importedCount == 1 ? "1 imported" : "\(importedCount) imported"
        }
        return "Forwarded emails appear here"
    }
}

// =============================================================================

