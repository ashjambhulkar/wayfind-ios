import Foundation

/// Minimal trip shape for Expo `tripListBuckets` parity (profile aggregates + spotlight).
struct ProfileTripBucketInput: Sendable, Hashable {
    let id: UUID
    let startDateISO: String?
    let endDateISO: String?
    let status: String
    let isActive: Bool
}

/// Ports `utils/tripListBuckets.ts` for profile stats and spotlight selection.
enum ProfileTripBucketing {
    private static let calendar = Calendar.current

    static func localDateKey(_ date: Date = Date()) -> String {
        SupabaseModelMapping.calendarDateOnlyString(from: date, calendar: calendar)
    }

    static func compareIsoDates(_ a: String?, _ b: String?) -> Int {
        if a == b { return 0 }
        guard let a, !a.isEmpty else { return 1 }
        guard let b, !b.isEmpty else { return -1 }
        return a < b ? -1 : (a > b ? 1 : 0)
    }

    private static func isCompletedOrPast(_ trip: ProfileTripBucketInput, today: String) -> Bool {
        if trip.status == "completed" { return true }
        if let end = trip.endDateISO, compareIsoDates(end, today) < 0 { return true }
        return false
    }

    private static func isInDateRange(_ trip: ProfileTripBucketInput, today: String) -> Bool {
        guard let start = trip.startDateISO, let end = trip.endDateISO else { return false }
        return compareIsoDates(today, start) >= 0 && compareIsoDates(today, end) <= 0
    }

    static func collectCurrentTrips(_ trips: [ProfileTripBucketInput]) -> [ProfileTripBucketInput] {
        let today = localDateKey()
        var ids = Set<UUID>()
        var ordered: [ProfileTripBucketInput] = []
        let add: (ProfileTripBucketInput) -> Void = { t in
            guard !ids.contains(t.id) else { return }
            ids.insert(t.id)
            ordered.append(t)
        }
        for t in trips where t.isActive { add(t) }
        for t in trips where !isCompletedOrPast(t, today: today) && isInDateRange(t, today: today) {
            add(t)
        }
        for t in trips where t.status == "active" && !isCompletedOrPast(t, today: today) {
            add(t)
        }
        return ordered
    }

    static func pickHeroTrip(_ trips: [ProfileTripBucketInput]) -> ProfileTripBucketInput? {
        collectCurrentTrips(trips).first
    }

    private struct Buckets {
        let currentTrips: [ProfileTripBucketInput]
        let upcoming: [ProfileTripBucketInput]
    }

    private static func bucketTrips(_ trips: [ProfileTripBucketInput]) -> Buckets {
        let today = localDateKey()
        let currentTrips = collectCurrentTrips(trips)
        let currentIds = Set(currentTrips.map(\.id))
        let rest = trips.filter { !currentIds.contains($0.id) }
        var upcoming: [ProfileTripBucketInput] = []
        var past: [ProfileTripBucketInput] = []

        for t in rest {
            if isCompletedOrPast(t, today: today) {
                past.append(t)
                continue
            }
            if let start = t.startDateISO, compareIsoDates(start, today) > 0 {
                upcoming.append(t)
                continue
            }
            if let start = t.startDateISO, let end = t.endDateISO,
               compareIsoDates(start, today) <= 0, compareIsoDates(end, today) >= 0 {
                upcoming.append(t)
                continue
            }
            if t.startDateISO == nil && t.status == "planned" {
                upcoming.append(t)
                continue
            }
            past.append(t)
        }

        upcoming.sort { compareIsoDates($0.startDateISO, $1.startDateISO) < 0 }
        past.sort { compareIsoDates($1.endDateISO ?? $1.startDateISO, $0.endDateISO ?? $0.startDateISO) < 0 }

        return Buckets(currentTrips: currentTrips, upcoming: upcoming)
    }

    static func countUpcomingOrActiveTrips(_ trips: [ProfileTripBucketInput]) -> Int {
        let b = bucketTrips(trips)
        return b.currentTrips.count + b.upcoming.count
    }

    enum SpotlightKind: Sendable {
        case current
        case upcoming
    }

    /// Picks spotlight trip from full `Trip` models using calendar dates + DB flags when available.
    static func pickProfileSpotlight(from trips: [Trip]) -> (trip: Trip, kind: SpotlightKind)? {
        let inputs = trips.map(bucketInput(from:))
        if let hero = pickHeroTrip(inputs), let full = trips.first(where: { $0.id == hero.id }) {
            return (full, .current)
        }
        let upcoming = bucketTrips(inputs).upcoming
        if let first = upcoming.first, let full = trips.first(where: { $0.id == first.id }) {
            return (full, .upcoming)
        }
        return nil
    }

    private static func bucketInput(from trip: Trip) -> ProfileTripBucketInput {
        let startISO = SupabaseModelMapping.calendarDateOnlyString(from: trip.startDate, calendar: calendar)
        let endISO = SupabaseModelMapping.calendarDateOnlyString(from: trip.endDate, calendar: calendar)
        let status = databaseStatusString(for: trip)
        let isActive = trip.isMarkedActiveOnServer
        return ProfileTripBucketInput(
            id: trip.id,
            startDateISO: startISO,
            endDateISO: endISO,
            status: status,
            isActive: isActive
        )
    }

    /// DB `trips.status` when synced from Supabase; otherwise inferred from dates (mock / offline).
    private static func databaseStatusString(for trip: Trip) -> String {
        if let explicit = trip.databaseStatus?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            return explicit
        }
        return SupabaseModelMapping.inferTripStatus(startDate: trip.startDate, endDate: trip.endDate, calendar: calendar)
    }
}


// =============================================================================

