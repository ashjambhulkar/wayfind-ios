import Observation
import SwiftUI

@Observable @MainActor
final class TabNavigationCoordinator {
    /// The trip currently being viewed. `nil` means trip-list mode.
    var activeTrip: Trip?

    /// Tabs available in trip-detail mode.
    enum DetailTab: Hashable {
        case map, budget, bookings, ai
    }

    /// Currently selected detail tab (only meaningful when `activeTrip != nil`).
    var detailTab: DetailTab = .map

    /// Navigate into a trip's detail tabs.
    func openTrip(_ trip: Trip) {
        activeTrip = trip
        detailTab = .map
    }

    /// Return to the trip list.
    func returnToList() {
        activeTrip = nil
    }
}

