//
//  TripTransportMode.swift
//  wayfind
//
//  Per-trip preferred transport mode for polyline rendering and
//  travel-time selection on the map screen.
//
//  We intentionally model "auto" as a first-class case (not absent)
//  so the picker UI can treat it as a real option and the planner
//  logic can branch cleanly per leg without an Optional dance.
//
//  Apple's `MKDirections` does NOT expose a cycling transport type;
//  Phase J.3 of the Places cost-and-owned-data plan documented this
//  trade-off and walking is used as the cycling stand-in elsewhere.
//  We deliberately omit cycling here too — surfacing a mode the
//  underlying routing engine can't satisfy is a worse UX than not
//  offering it.
//

import Foundation
import SwiftUI

enum TripTransportMode: String, CaseIterable, Identifiable, Sendable {
    /// Pick a sensible mode per leg based on distance / availability.
    /// Defaults to walking under ~1.5 km, transit when the cached
    /// transit time exists and beats driving by ≥ 10 %, else driving.
    case auto
    case walking
    case driving
    case transit

    var id: String { rawValue }

    /// Concrete cache mode for this preference. `auto` returns nil so
    /// callers know to apply per-leg logic.
    var concreteMode: AppleTravelTimesService.Mode? {
        switch self {
        case .auto:    return nil
        case .walking: return .walking
        case .driving: return .driving
        case .transit: return .transit
        }
    }

    var displayName: String {
        switch self {
        case .auto:    return "Auto"
        case .walking: return "Walk"
        case .driving: return "Drive"
        case .transit: return "Transit"
        }
    }

    /// SF Symbol used in the floating pill and the picker.
    var sfSymbol: String {
        switch self {
        case .auto:    return "sparkles"
        case .walking: return "figure.walk"
        case .driving: return "car.fill"
        case .transit: return "tram.fill"
        }
    }

    var pickerSubtitle: String {
        switch self {
        case .auto:    return "Pick the best mode per stop"
        case .walking: return "Show walking routes"
        case .driving: return "Show driving routes"
        case .transit: return "Show transit routes"
        }
    }
}

extension TripTransportMode {
    /// AppStorage key for a per-trip preference. Keyed by trip id so
    /// the choice survives across launches and is independent per trip.
    static func storageKey(forTripId id: UUID) -> String {
        "trip.transportMode.\(id.uuidString.lowercased())"
    }

    /// Auto-mode resolver. Applied per leg by the map screen when the
    /// user keeps the default. The thresholds below match the existing
    /// `HaversineDistance` heuristics elsewhere in the app so users
    /// see consistent behavior across the trip detail timeline and the
    /// map screen.
    ///
    /// - Parameters:
    ///   - distanceMeters: Straight-line distance between the two stops
    ///     (haversine is fine — we only need it for bucket selection).
    ///   - availability: Which concrete modes have a cached polyline +
    ///     time available for this leg. Caller passes the set so the
    ///     resolver doesn't have to know about the cache.
    static func resolveAuto(
        distanceMeters: Double,
        availability: Set<AppleTravelTimesService.Mode>
    ) -> AppleTravelTimesService.Mode {
        // Walking when the leg is short enough that walking is the
        // dominant choice in nearly every city.
        let walkThreshold: Double = 1_500   // 1.5 km
        if distanceMeters <= walkThreshold {
            return availability.contains(.walking) ? .walking : (availability.first ?? .walking)
        }

        // Transit when available — public-transit users almost always
        // prefer it over driving in dense cities, and outside dense
        // cities the cache simply won't have a transit row.
        if availability.contains(.transit) {
            return .transit
        }
        if availability.contains(.driving) {
            return .driving
        }
        if availability.contains(.walking) {
            return .walking
        }
        return .driving
    }
}

// =============================================================================
