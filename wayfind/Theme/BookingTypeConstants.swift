//
//  BookingTypeConstants.swift
//  wayfind
//
//  Created by Ashish Jambhulkar on 4/2/26.
//

import SwiftUI

enum BookingCategory: String, CaseIterable, Codable {
    case flight
    case hotel
    case restaurant
    case carRental
    case activity
    case transport

    var color: Color {
        switch self {
        case .flight:
            Color(red: 59 / 255, green: 130 / 255, blue: 246 / 255)
        case .hotel:
            Color(red: 168 / 255, green: 85 / 255, blue: 247 / 255)
        case .restaurant:
            Color(red: 194 / 255, green: 111 / 255, blue: 75 / 255)
        case .carRental:
            Color(red: 8 / 255, green: 145 / 255, blue: 178 / 255)
        case .activity:
            Color(red: 202 / 255, green: 138 / 255, blue: 4 / 255)
        case .transport:
            Color(red: 4 / 255, green: 120 / 255, blue: 87 / 255)
        }
    }

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

