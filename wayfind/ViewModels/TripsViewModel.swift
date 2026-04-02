import Foundation
import Observation

enum TripSortOrder: String, CaseIterable {
    case date
    case name
}

@MainActor
@Observable
final class TripsViewModel {
    private let mockDataService: MockDataService

    var trips: [Trip] = []
    var searchText: String = ""
    var isLoading: Bool = false
    var sortOrder: TripSortOrder = .date

    init(mockDataService: MockDataService) {
        self.mockDataService = mockDataService
    }

    var filteredTrips: [Trip] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return trips }
        let lower = q.lowercased()
        return trips.filter {
            $0.title.lowercased().contains(lower) || $0.destination.lowercased().contains(lower)
        }
    }

    var activeTrip: Trip? {
        filteredTrips.first { $0.status == .active }
    }

    var upcomingTrips: [Trip] {
        let base = filteredTrips.filter { $0.status == .upcoming }
        return sortedTrips(base, for: .upcoming)
    }

    var pastTrips: [Trip] {
        let base = filteredTrips.filter { $0.status == .past }
        return sortedTrips(base, for: .past)
    }

    func loadTrips() async {
        isLoading = true
        defer { isLoading = false }
        trips = await mockDataService.fetchTrips()
    }

    func deleteTrip(_ trip: Trip) async {
        trips.removeAll { $0.id == trip.id }
        await mockDataService.deleteTrip(id: trip.id)
    }

    func undoDelete(_ trip: Trip) async {
        trips.append(trip)
        await mockDataService.addTrip(trip)
    }

    private func sortedTrips(_ list: [Trip], for kind: TripKind) -> [Trip] {
        switch sortOrder {
        case .date:
            switch kind {
            case .upcoming:
                return list.sorted { $0.startDate < $1.startDate }
            case .past:
                return list.sorted { $0.endDate > $1.endDate }
            }
        case .name:
            return list.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }
    }

    private enum TripKind {
        case upcoming
        case past
    }
}