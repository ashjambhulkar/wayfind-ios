import SwiftUI

/// Wraps the map view for the iOS 26 trip map module. The places sheet is
/// presented from `TripMapView` so it can host `MapSearchOverlay` inline.
@available(iOS 26.0, *)
struct MapTabWrapper: View {
    let trip: Trip
    let mapState: MapTabSharedState

    var body: some View {
        TripMapView(trip: trip, sharedState: mapState)
            .onDisappear {
                mapState.showPlacesSheet = false
            }
    }
}
