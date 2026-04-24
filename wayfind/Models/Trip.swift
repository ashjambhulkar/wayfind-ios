//
//  Trip.swift
//  wayfind
//
//  Created by Ashish Jambhulkar on 4/2/26.
//

import Foundation

struct Trip: Identifiable, Codable, Hashable {
    let id: UUID
    var userId: UUID
    var title: String
    var destination: String
    var lat: Double?
    var lng: Double?
    var startDate: Date
    var endDate: Date
    var coverImageUrl: String?
    var coverImageAttribution: String?
    var notes: String?
    var createdAt: Date
    /// Mirrors Supabase `trips.updated_at` (used for “Recently updated” sort).
    var updatedAt: Date
    /// `trips.status` when loaded from Supabase; `nil` means infer from dates (mock/offline).
    var databaseStatus: String? = nil
    /// `trips.is_active` when loaded from Supabase.
    var isMarkedActiveOnServer: Bool = false

    var dayCount: Int {
        let days = Calendar.current.dateComponents([.day], from: startDate, to: endDate).day ?? 0
        return days + 1
    }

    var status: TripStatus {
        let now = Date()
        if now < startDate {
            return .upcoming
        } else if now > endDate {
            return .past
        } else {
            return .active
        }
    }

    var currentDayNumber: Int? {
        guard status == .active else { return nil }
        let day = Calendar.current.dateComponents([.day], from: startDate, to: Date()).day ?? 0
        return day + 1
    }

    var daysUntilStart: Int? {
        guard status == .upcoming else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: startDate).day
    }
}

enum TripStatus {
    case upcoming, active, past
}


// =============================================================================

