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

    // MARK: – city_places enrichment (joined via place_id / googlePlaceId)
    var heroImageUrl: String?          // city_places.thumbnail_url
    var rating: Double?                // city_places.rating
    var userRatingsTotal: Int?         // city_places.user_ratings_total
    var priceLevel: Int?               // city_places.price_level (1–4)
    var website: String?               // city_places.website
    var phoneNumber: String?           // city_places.formatted_phone_number
    var isOpenNow: Bool?               // derived from city_places.opening_hours
    var openingHoursText: String?      // e.g. "Open · Closes 10 PM"
    var aiSummary: String?             // city_places.ai_editorial_summary
    var aiShortSummary: String?        // city_places.ai_short_summary
    var whyGo: [String]?               // city_places.ai_why_go
    var knowBeforeYouGo: [String]?     // city_places.ai_know_before_you_go
    var reviewsTags: [String]?         // city_places.reviews_tags
    var durationMinutes: Int?          // city_places.time_spent_min (suggested visit length)
    var subtypes: [String]?            // city_places.subtypes — e.g. ["Shopping mall", "Tourist attraction"]

    // MARK: – stored travel hop (trip_activities.travel_from_previous_minutes/mode)
    /// Real, stored travel time **from the previous stop** to this one. When
    /// present we prefer it over our haversine estimate in `TimelineGapView`.
    var travelFromPreviousMinutes: Int?
    /// Stored travel mode for the same hop (e.g. "driving", "walking",
    /// "transit"). Falls back to the estimator's heuristic when nil.
    var travelMode: String?

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

    /// Human-friendly label for the most specific Google subtype, e.g.
    /// `"shopping_mall"` → `"Shopping mall"`. Returns `nil` when no subtypes
    /// are present so callers can fall back to the broader category label.
    /// We intentionally drop the catch-all buckets (`point_of_interest`,
    /// `establishment`, `tourist_attraction`) — they read as filler in the UI.
    var placeKindLabel: String? {
        guard let subtypes else { return nil }
        let blacklist: Set<String> = [
            "point_of_interest", "establishment", "tourist_attraction", "place_of_interest",
        ]
        let pick = subtypes.first { !blacklist.contains($0.lowercased()) } ?? subtypes.first
        guard let raw = pick, !raw.isEmpty else { return nil }
        let words = raw.replacingOccurrences(of: "_", with: " ").split(separator: " ")
        guard let first = words.first else { return nil }
        let head = first.prefix(1).uppercased() + first.dropFirst().lowercased()
        let tail = words.dropFirst().map { $0.lowercased() }
        return ([head] + tail).joined(separator: " ")
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


// =============================================================================

