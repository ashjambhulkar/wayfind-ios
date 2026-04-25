//
//  MapSearchPreview.swift
//  wayfind
//
//  Provider-agnostic shape for "a place we found via search." Three origins:
//
//    • .apple         — produced by `AppleMapSearchService` (MapKit). Free.
//    • .cityPlaces    — produced by `CityPlacesSearchService` from an
//                       existing row in the `city_places` table. Zero
//                       outbound network — money was already spent the
//                       first time someone enriched this city.
//    • .googleFallback — produced by `PlaceSearchService` for trips inside
//                       mainland China where MapKit data is sparse. Costs
//                       exactly one Place Details call per *selection*,
//                       never per pin render.
//
//  The preview sheet, the search-result annotation, and the add-to-day flow
//  all consume this type so they don't have to branch on provider.
//

import CoreLocation
import Foundation

struct MapSearchPreview: Identifiable, Hashable {

    enum Origin: String, Hashable {
        case apple
        case cityPlaces
        case googleFallback
    }

    /// Stable across re-runs of the same query so MKMapView can diff
    /// annotations without flicker. For Apple results it's
    /// "title|subtitle|lat|lng" rounded to 5 decimals; for city_places
    /// it's the row's Google `place_id`; for the China fallback it's
    /// the Google place_id from the Place Details call.
    let id: String

    let origin: Origin
    let name: String

    /// Single-line address-y string. May be empty for very generic
    /// MapKit hits (e.g. "Mountain"); the preview sheet hides the
    /// address row in that case.
    let subtitle: String

    let coordinate: CLLocationCoordinate2D

    /// Set when we already know the Google `place_id` — common for
    /// .cityPlaces and .googleFallback, rare-but-possible for .apple
    /// once `PlaceIdBridgeService` has run successfully in the past.
    var googlePlaceId: String?

    var phone: String?
    var website: URL?
    var thumbnailURL: URL?

    /// Best-effort category for the leading icon. Populated for
    /// .cityPlaces (`wayfind_category` column) and for .apple when we
    /// can map an `MKMapItem.pointOfInterestCategory` to one of ours.
    var category: PlaceCategory?

    /// True when this preview came from a row we already paid to
    /// enrich. The annotation view paints a small accent dot in the
    /// lower-trailing corner so the user knows we know more about it.
    var isOwnedRow: Bool { origin == .cityPlaces }

    // MARK: - Hashable / Equatable

    static func == (lhs: MapSearchPreview, rhs: MapSearchPreview) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// =============================================================================
