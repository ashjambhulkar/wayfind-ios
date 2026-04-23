//
//  BookingDetails.swift
//  wayfind
//
//  Created by Ashish Jambhulkar on 4/2/26.
//

import Foundation

struct FlightDetails: Codable, Hashable {
    var airline: String
    var flightNumber: String
    var departureAirport: String
    var arrivalAirport: String
    var departureTime: Date?
    var arrivalTime: Date?
    var terminal: String
    var gate: String
    var seat: String
}

struct HotelDetails: Codable, Hashable {
    var checkInDate: Date?
    var checkInTime: String?
    var checkOutDate: Date?
    var checkOutTime: String?
    var roomType: String
    var nights: Int?
}

struct RestaurantDetails: Codable, Hashable {
    var reservationTime: Date?
    var partySize: Int?
}

struct CarRentalDetails: Codable, Hashable {
    var company: String
    var pickupLocation: String
    var dropoffLocation: String
    var pickupTime: Date?
    var dropoffTime: Date?
    var carType: String
}

struct ActivityDetails: Codable, Hashable {
    var provider: String
    var duration: String?
    var ticketNumber: String
}

struct TransportDetails: Codable, Hashable {
    var operatorName: String
    var serviceNumber: String
    var departureStation: String
    var arrivalStation: String
    var departureTime: Date?
    var arrivalTime: Date?
    var seat: String
}

private enum BookingPayloadKind: String, Codable {
    case flight
    case hotel
    case restaurant
    case carRental
    case activity
    case transport
}

enum BookingDetailUnion: Codable, Hashable {
    case flight(FlightDetails)
    case hotel(HotelDetails)
    case restaurant(RestaurantDetails)
    case carRental(CarRentalDetails)
    case activity(ActivityDetails)
    case transport(TransportDetails)

    private enum CodingKeys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(BookingPayloadKind.self, forKey: .type)
        switch kind {
        case .flight:
            self = .flight(try FlightDetails(from: decoder))
        case .hotel:
            self = .hotel(try HotelDetails(from: decoder))
        case .restaurant:
            self = .restaurant(try RestaurantDetails(from: decoder))
        case .carRental:
            self = .carRental(try CarRentalDetails(from: decoder))
        case .activity:
            self = .activity(try ActivityDetails(from: decoder))
        case .transport:
            self = .transport(try TransportDetails(from: decoder))
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .flight(let details):
            try FlightTagged(details: details).encode(to: encoder)
        case .hotel(let details):
            try HotelTagged(details: details).encode(to: encoder)
        case .restaurant(let details):
            try RestaurantTagged(details: details).encode(to: encoder)
        case .carRental(let details):
            try CarRentalTagged(details: details).encode(to: encoder)
        case .activity(let details):
            try ActivityTagged(details: details).encode(to: encoder)
        case .transport(let details):
            try TransportTagged(details: details).encode(to: encoder)
        }
    }
}

private struct FlightTagged: Encodable {
    let details: FlightDetails

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(BookingPayloadKind.flight, forKey: .type)
        try container.encode(details.airline, forKey: .airline)
        try container.encode(details.flightNumber, forKey: .flightNumber)
        try container.encode(details.departureAirport, forKey: .departureAirport)
        try container.encode(details.arrivalAirport, forKey: .arrivalAirport)
        try container.encodeIfPresent(details.departureTime, forKey: .departureTime)
        try container.encodeIfPresent(details.arrivalTime, forKey: .arrivalTime)
        try container.encode(details.terminal, forKey: .terminal)
        try container.encode(details.gate, forKey: .gate)
        try container.encode(details.seat, forKey: .seat)
    }

    enum CodingKeys: String, CodingKey {
        case type
        case airline
        case flightNumber
        case departureAirport
        case arrivalAirport
        case departureTime
        case arrivalTime
        case terminal
        case gate
        case seat
    }
}

private struct HotelTagged: Encodable {
    let details: HotelDetails

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(BookingPayloadKind.hotel, forKey: .type)
        try container.encodeIfPresent(details.checkInDate, forKey: .checkInDate)
        try container.encodeIfPresent(details.checkInTime, forKey: .checkInTime)
        try container.encodeIfPresent(details.checkOutDate, forKey: .checkOutDate)
        try container.encodeIfPresent(details.checkOutTime, forKey: .checkOutTime)
        try container.encode(details.roomType, forKey: .roomType)
        try container.encodeIfPresent(details.nights, forKey: .nights)
    }

    enum CodingKeys: String, CodingKey {
        case type
        case checkInDate
        case checkInTime
        case checkOutDate
        case checkOutTime
        case roomType
        case nights
    }
}

private struct RestaurantTagged: Encodable {
    let details: RestaurantDetails

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(BookingPayloadKind.restaurant, forKey: .type)
        try container.encodeIfPresent(details.reservationTime, forKey: .reservationTime)
        try container.encodeIfPresent(details.partySize, forKey: .partySize)
    }

    enum CodingKeys: String, CodingKey {
        case type
        case reservationTime
        case partySize
    }
}

private struct CarRentalTagged: Encodable {
    let details: CarRentalDetails

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(BookingPayloadKind.carRental, forKey: .type)
        try container.encode(details.company, forKey: .company)
        try container.encode(details.pickupLocation, forKey: .pickupLocation)
        try container.encode(details.dropoffLocation, forKey: .dropoffLocation)
        try container.encodeIfPresent(details.pickupTime, forKey: .pickupTime)
        try container.encodeIfPresent(details.dropoffTime, forKey: .dropoffTime)
        try container.encode(details.carType, forKey: .carType)
    }

    enum CodingKeys: String, CodingKey {
        case type
        case company
        case pickupLocation
        case dropoffLocation
        case pickupTime
        case dropoffTime
        case carType
    }
}

private struct ActivityTagged: Encodable {
    let details: ActivityDetails

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(BookingPayloadKind.activity, forKey: .type)
        try container.encode(details.provider, forKey: .provider)
        try container.encodeIfPresent(details.duration, forKey: .duration)
        try container.encode(details.ticketNumber, forKey: .ticketNumber)
    }

    enum CodingKeys: String, CodingKey {
        case type
        case provider
        case duration
        case ticketNumber
    }
}

private struct TransportTagged: Encodable {
    let details: TransportDetails

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(BookingPayloadKind.transport, forKey: .type)
        try container.encode(details.operatorName, forKey: .operatorName)
        try container.encode(details.serviceNumber, forKey: .serviceNumber)
        try container.encode(details.departureStation, forKey: .departureStation)
        try container.encode(details.arrivalStation, forKey: .arrivalStation)
        try container.encodeIfPresent(details.departureTime, forKey: .departureTime)
        try container.encodeIfPresent(details.arrivalTime, forKey: .arrivalTime)
        try container.encode(details.seat, forKey: .seat)
    }

    enum CodingKeys: String, CodingKey {
        case type
        case operatorName
        case serviceNumber
        case departureStation
        case arrivalStation
        case departureTime
        case arrivalTime
        case seat
    }
}
