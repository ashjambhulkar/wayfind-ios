import MapKit
import SwiftUI

enum TripMapMode: String, CaseIterable, Identifiable {
    case hybrid
    case map

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hybrid:
            return "Hybrid"
        case .map:
            return "Map"
        }
    }

    var subtitle: String {
        switch self {
        case .hybrid:
            return "Satellite imagery with roads"
        case .map:
            return "Standard Apple map"
        }
    }

    var sfSymbol: String {
        switch self {
        case .hybrid:
            return "map.fill"
        case .map:
            return "map"
        }
    }

    var mapStyle: MapStyle {
        switch self {
        case .hybrid:
            return .hybrid(elevation: .realistic)
        case .map:
            return .standard(elevation: .realistic)
        }
    }
}

// =============================================================================

