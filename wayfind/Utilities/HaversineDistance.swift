//
//  HaversineDistance.swift
//  wayfind
//
//  Created by Ashish Jambhulkar on 4/2/26.
//

import CoreLocation

enum HaversineDistance {
    static func distance(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let R = 6371.0
        let dLat = (to.latitude - from.latitude) * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) +
            cos(from.latitude * .pi / 180) * cos(to.latitude * .pi / 180) *
            sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return R * c
    }

    enum TravelMode {
        case driving, walking, cycling, transit

        var multiplier: Double {
            switch self {
            case .driving: return 1.4
            case .walking: return 1.3
            case .cycling: return 1.3
            case .transit: return 1.5
            }
        }

        var speedKmh: Double {
            switch self {
            case .driving: return 35
            case .walking: return 5
            case .cycling: return 15
            case .transit: return 25
            }
        }

        var sfSymbol: String {
            switch self {
            case .driving: return "car.fill"
            case .walking: return "figure.walk"
            case .cycling: return "bicycle"
            case .transit: return "tram.fill"
            }
        }
    }

    static func estimateTravelTime(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, mode: TravelMode) -> Int {
        let km = distance(from: from, to: to)
        return Int((km * mode.multiplier / mode.speedKmh * 60).rounded())
    }
}

