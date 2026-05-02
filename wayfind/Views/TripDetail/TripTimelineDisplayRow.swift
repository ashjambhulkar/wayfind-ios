import Foundation

/// Distinguishes hotel **check-in** vs **check-out** cards when a stay is split
/// across two (or more) calendar days on the trip timeline.
enum HotelTimelineDisplayRole: Hashable {
    case checkIn
    case checkOut
}

/// One rendered row in a day’s timeline (place or booking), with optional hotel
/// role when a single `Place` expands to multiple rows.
struct TripTimelineDisplayRow: Identifiable {
    let id: String
    let place: Place
    /// Set for hotel rows created from `checkInDate` / `checkOutDate`; `nil`
    /// for all non-hotel content and for legacy single-card hotel fallback.
    var hotelTimelineRole: HotelTimelineDisplayRole?

    /// Sort key for ordering mixed native + injected rows within a day.
    var timelineSortInstant: Date? {
        switch hotelTimelineRole {
        case .checkIn:
            if case .hotel(let h) = place.bookingDetails { return h.checkInDate ?? place.startTime }
            return place.startTime
        case .checkOut:
            if case .hotel(let h) = place.bookingDetails { return h.checkOutDate ?? place.startTime }
            return place.startTime
        case nil:
            return place.startTime
        }
    }

    /// Tie-break check-in before check-out when instants are equal.
    var roleOrderingIndex: Int {
        switch hotelTimelineRole {
        case .checkIn: return 0
        case .checkOut: return 1
        case nil: return 0
        }
    }
}

enum TripTimelineRowCalendar {
    /// Whether `hotelDate` falls on the same calendar day as the itinerary
    /// day anchor, interpreted in `timelineTimeZone` (trip timeline display TZ).
    static func isSameCalendarDay(
        hotelDate: Date?,
        itineraryAnchor: Date,
        timelineTimeZone: TimeZone
    ) -> Bool {
        guard let hotelDate else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timelineTimeZone
        return calendar.isDate(hotelDate, inSameDayAs: itineraryAnchor)
    }
}
