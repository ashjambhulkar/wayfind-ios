import Foundation

/// Mirrors Expo `ProfileAggregateStats` / `fetchProfileAggregateStats`.
struct ProfileAggregateStats: Equatable, Sendable {
    var tripCount: Int
    var upcomingOrActiveCount: Int
    var distinctPlaceCount: Int
    var importedBookingCount: Int

    static let empty = ProfileAggregateStats(
        tripCount: 0,
        upcomingOrActiveCount: 0,
        distinctPlaceCount: 0,
        importedBookingCount: 0
    )
}

