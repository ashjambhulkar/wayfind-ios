//
//  FlightStatus.swift
//  wayfind
//
//  Wave 3 — local mirror of `public.flight_statuses` rows. Decoded from
//  PostgREST + the realtime payload the `poll-flight-status` Edge
//  Function writes. Exposes a UI-friendly `displayState` so views can
//  switch on a closed enum instead of stringly-typed status codes.
//

import Foundation

struct FlightStatus: Identifiable, Sendable, Hashable, Decodable {
    let id: UUID
    let bookingId: UUID
    let tripId: UUID
    let userId: UUID

    let carrierIata: String
    let flightNumber: String

    let scheduledDepartureUTC: Date
    let scheduledArrivalUTC: Date
    let estimatedDepartureUTC: Date?
    let estimatedArrivalUTC: Date?
    let actualDepartureUTC: Date?
    let actualArrivalUTC: Date?

    let status: String
    let originAirportIata: String?
    let destinationAirportIata: String?
    let gateOrigin: String?
    let gateDestination: String?
    let terminalOrigin: String?
    let terminalDestination: String?
    let baggageClaim: String?
    let delayMinutes: Int?

    let provider: String?
    let polledAt: Date
    let nextPollAt: Date?
    let lastChangeSummary: String?

    enum DisplayState: String, Sendable {
        case scheduled
        case active
        case landed
        case cancelled
        case diverted
        case unknown

        /// Coarse colour bucket. Drives the badge tint in `FlightStatusBadge`.
        /// Green = on-time / scheduled / landed without delay,
        /// amber = delayed / stale data,
        /// red   = cancelled / diverted.
        enum Tint: Sendable { case green, amber, red, neutral }
    }

    var displayState: DisplayState {
        DisplayState(rawValue: status.lowercased()) ?? .unknown
    }

    /// Combines the raw provider state with the delay buffer so a
    /// "scheduled but +30m" flight shows amber, not green.
    func tint(now: Date = Date(), staleAfter staleSeconds: TimeInterval) -> DisplayState.Tint {
        if isStale(now: now, staleAfter: staleSeconds) { return .amber }
        switch displayState {
        case .cancelled, .diverted: return .red
        case .landed: return .green
        case .scheduled, .active:
            if let delay = delayMinutes, delay >= 15 { return .amber }
            return .green
        case .unknown: return .neutral
        }
    }

    /// "We haven't heard back from the provider in long enough that we're
    /// no longer confident". Drives the amber dot + subtitle copy.
    func isStale(now: Date = Date(), staleAfter staleSeconds: TimeInterval) -> Bool {
        now.timeIntervalSince(polledAt) > staleSeconds
    }
}

extension FlightStatus {
    enum CodingKeys: String, CodingKey {
        case id
        case bookingId = "booking_id"
        case tripId = "trip_id"
        case userId = "user_id"
        case carrierIata = "carrier_iata"
        case flightNumber = "flight_number"
        case scheduledDepartureUTC = "scheduled_departure_utc"
        case scheduledArrivalUTC = "scheduled_arrival_utc"
        case estimatedDepartureUTC = "estimated_departure_utc"
        case estimatedArrivalUTC = "estimated_arrival_utc"
        case actualDepartureUTC = "actual_departure_utc"
        case actualArrivalUTC = "actual_arrival_utc"
        case status
        case originAirportIata = "origin_airport_iata"
        case destinationAirportIata = "destination_airport_iata"
        case gateOrigin = "gate_origin"
        case gateDestination = "gate_destination"
        case terminalOrigin = "terminal_origin"
        case terminalDestination = "terminal_destination"
        case baggageClaim = "baggage_claim"
        case delayMinutes = "delay_minutes"
        case provider
        case polledAt = "polled_at"
        case nextPollAt = "next_poll_at"
        case lastChangeSummary = "last_change_summary"
    }
}
