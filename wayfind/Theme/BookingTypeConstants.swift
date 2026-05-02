//
//  BookingTypeConstants.swift
//  wayfind
//
//  Created by Ashish Jambhulkar on 4/2/26.
//

import SwiftUI

enum BookingCategory: String, CaseIterable, Codable, Identifiable {
    case flight
    case hotel
    case restaurant
    case carRental
    case activity
    case transport

    var id: String { rawValue }

    /// Sourced from `PlaceCategoryFamily` so all transport-y bookings share a
    /// hue, all stays share a hue, etc. — see `PlaceTypeRegistry.swift`.
    var color: Color { family.color }

    var sfSymbol: String {
        switch self {
        case .flight: "airplane"
        case .hotel: "bed.double.fill"
        case .restaurant: "fork.knife"
        case .carRental: "car.fill"
        case .activity: "ticket.fill"
        case .transport: "tram.fill"
        }
    }

    var label: String {
        switch self {
        case .flight: "Flight"
        case .hotel: "Hotel"
        case .restaurant: "Restaurant"
        case .carRental: "Car Rental"
        case .activity: "Activity"
        case .transport: "Transport"
        }
    }

    /// Timeline banner / collapsed-day preview when a booking spans another itinerary day (not hotel-only “staying”).
    func ongoingSpanHeadline(bookingName: String) -> String {
        let trimmed = bookingName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? String(localized: "Booking") : trimmed
        switch self {
        case .hotel:
            return String(localized: "Staying at \(name)")
        case .carRental:
            return String(localized: "Renting from \(name)")
        case .transport:
            return String(localized: "Transit · \(name)")
        case .flight:
            return String(localized: "Flight · \(name)")
        case .restaurant:
            return String(localized: "Reservation · \(name)")
        case .activity:
            return String(localized: "Activity · \(name)")
        }
    }
}

enum PlaceCategory: String, CaseIterable, Codable {
    case attraction
    case restaurant
    case hotel
    case transport
    case shopping
    case nightlife
    case nature
    case custom

    var sfSymbol: String {
        switch self {
        case .attraction: "star.fill"
        case .restaurant: "fork.knife"
        case .hotel: "bed.double.fill"
        case .transport: "car.fill"
        case .shopping: "bag.fill"
        case .nightlife: "wineglass.fill"
        case .nature: "leaf.fill"
        case .custom: "mappin.and.ellipse"
        }
    }

    var label: String {
        switch self {
        case .attraction: "Attraction"
        case .restaurant: "Restaurant"
        case .hotel: "Hotel"
        case .transport: "Transport"
        case .shopping: "Shopping"
        case .nightlife: "Nightlife"
        case .nature: "Nature"
        case .custom: "Custom"
        }
    }
}


// =============================================================================

