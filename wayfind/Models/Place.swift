//
//  Place.swift
//  wayfind
//
//  Created by Ashish Jambhulkar on 4/2/26.
//

import CoreLocation
import Foundation

struct Place: Identifiable, Codable, Hashable {
    let id: UUID
    var itineraryDayId: UUID
    var name: String
    var address: String?
    var lat: Double?
    var lng: Double?
    var category: String?
    var notes: String?
    var sortOrder: Int
    var startTime: Date?
    var endTime: Date?
    var isBooking: Bool
    var bookingType: String?
    var confirmationNumber: String?
    var bookingDetails: BookingDetailUnion?
    var googlePlaceId: String?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat ?? 0, longitude: lng ?? 0)
    }

    var categoryEnum: PlaceCategory {
        guard let raw = category?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .custom
        }
        if let match = PlaceCategory(rawValue: raw) {
            return match
        }
        let normalized = raw
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
        switch normalized {
        case "attraction", "sightseeing", "landmark": return .attraction
        case "restaurant", "food", "dining": return .restaurant
        case "hotel", "lodging", "accommodation": return .hotel
        case "transport", "transit", "transportation": return .transport
        case "shopping", "shop", "retail": return .shopping
        case "nightlife", "bar", "club": return .nightlife
        case "nature", "park", "outdoor": return .nature
        default: return .custom
        }
    }

    var bookingCategoryEnum: BookingCategory? {
        guard let raw = bookingType?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if let match = BookingCategory(rawValue: raw) {
            return match
        }
        let normalized = raw
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
        switch normalized {
        case "flight", "airline", "plane": return .flight
        case "hotel", "lodging", "accommodation": return .hotel
        case "restaurant", "dining", "food": return .restaurant
        case "carrental", "car", "rentalcar": return .carRental
        case "activity", "tour", "ticket": return .activity
        case "transport", "transit", "train", "bus": return .transport
        default: return nil
        }
    }
}

