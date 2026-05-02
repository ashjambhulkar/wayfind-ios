//
//  TripMapState.swift
//  wayfind
//
//  Search-only state for the trip map screen. Lives outside the day sheet
//  (which no longer drives search) and outside `MapTabSharedState` (which
//  belongs to the iOS 26 tab accessory bar). Keeping it isolated means a
//  future move into its own file or test target is a one-liner.
//
//  Phase 2 of the Map Screen Search Redesign plan.
//

import Foundation
import MapKit

@MainActor
@Observable
final class TripMapState {
    /// Live merged Apple + city_places previews currently rendered as
    /// search annotations on the map. Empty until the user opens the
    /// search overlay and commits a query.
    var searchResults: [MapSearchPreview] = []

    /// The preview the user is currently inspecting. When non-nil, the
    /// map screen swaps the day sheet's accessory for the preview sheet.
    var selectedSearchResult: MapSearchPreview?

    /// True while the floating search pill is expanded into the typing
    /// overlay. The map screen uses this to dim the day sheet behind the
    /// overlay.
    var isOverlayShown: Bool = false

    /// Region in which the most recent category search was launched. When
    /// the user pans far enough away from this region, the "Search this
    /// area" pill appears.
    var searchOriginRegion: MKCoordinateRegion?

    /// Google `place_id`s currently scheduled on this trip's days
    /// (excludes wishlist). Used by `CityPlacesSearchService` to filter
    /// out places already on the itinerary so the map never re-suggests
    /// them.
    var scheduledDayPlaceIds: Set<String> = []

    /// Recompute the exclude set from the trip's place list. O(n) over the
    /// places, called whenever the data layer pushes new rows.
    func recomputeScheduledDayPlaceIds(
        from places: [Place],
        wishlistDayIds: Set<UUID>
    ) {
        var ids = Set<String>()
        for place in places {
            guard !wishlistDayIds.contains(place.itineraryDayId),
                  let pid = place.googlePlaceId,
                  !pid.isEmpty
            else { continue }
            ids.insert(pid)
        }
        scheduledDayPlaceIds = ids
    }
}

// =============================================================================
