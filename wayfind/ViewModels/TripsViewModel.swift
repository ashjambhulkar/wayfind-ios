import Foundation
import Observation

@MainActor
@Observable
final class TripsViewModel {
    private let dataService: DataService
    private let preferences: UserPreferencesStore

    var trips: [Trip] = []
    var searchText: String = ""
    var isLoading: Bool = false

    init(dataService: DataService, preferences: UserPreferencesStore) {
        self.dataService = dataService
        self.preferences = preferences
    }

    var filteredTrips: [Trip] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return trips }
        let lower = q.lowercased()
        return trips.filter {
            $0.title.lowercased().contains(lower) || $0.destination.lowercased().contains(lower)
        }
    }

    var activeTrips: [Trip] {
        let base = filteredTrips.filter { $0.status == .active }
        return sortedTrips(base)
    }

    var upcomingTrips: [Trip] {
        let base = filteredTrips.filter { $0.status == .upcoming }
        return sortedTrips(base)
    }

    var pastTrips: [Trip] {
        let base = filteredTrips.filter { $0.status == .past }
        return sortedTrips(base)
    }

    func loadTrips() async {
        isLoading = true
        defer { isLoading = false }
        trips = await dataService.fetchTrips()
    }

    func deleteTrip(_ trip: Trip) async {
        trips.removeAll { $0.id == trip.id }
        await dataService.deleteTrip(id: trip.id)
    }

    func undoDelete(_ trip: Trip) async {
        trips.append(trip)
        await dataService.addTrip(trip)
    }

    private func sortedTrips(_ list: [Trip]) -> [Trip] {
        switch preferences.tripSortMode {
        case .startAsc:
            return list.sorted { $0.startDate < $1.startDate }
        case .startDesc:
            return list.sorted { $0.startDate > $1.startDate }
        case .name:
            return list.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        case .updated:
            return list.sorted { $0.updatedAt > $1.updatedAt }
        }
    }
}

