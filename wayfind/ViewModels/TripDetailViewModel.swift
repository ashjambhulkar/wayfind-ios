//
//  TripDetailViewModel.swift
//  wayfind
//
//  Created by Ashish Jambhulkar on 4/2/26.
//

import Foundation
import Observation

@Observable
@MainActor
final class TripDetailViewModel {
    private let dataService: DataService

    var trip: Trip
    var scheduledDays: [ItineraryDay] = []
    var wishlistPlaces: [Place] = []
    private(set) var wishlistDayId: UUID?
    var isLoading = false

    /// Hero pill counts (Expo `TripDetailHero` checklist / notes chips).
    var checklistDoneCount = 0
    var checklistTotalCount = 0
    var noteCount = 0

    private var placesByDayId: [UUID: [Place]] = [:]
    private var collapsedDayIds: Set<UUID> = []
    private var timelineLoadGeneration = 0
    private var shortcutCountsLoadGeneration = 0
    private var hasLoadedShortcutCounts = false

    init(trip: Trip, dataService: DataService) {
        self.trip = trip
        self.dataService = dataService
    }

    func places(for day: ItineraryDay) -> [Place] {
        placesByDayId[day.id] ?? []
    }

    func allScheduledPlaces() -> [Place] {
        scheduledDays.flatMap { places(for: $0) }
    }

    func placesCount(for day: ItineraryDay) -> Int {
        places(for: day).count
    }

    /// Place ids for non-booking activities on the timeline (and ideas), for activity photo stacks.
    func nonBookingTimelineActivityIds() -> [UUID] {
        var ids: [UUID] = []
        ids.reserveCapacity(24)
        for day in scheduledDays {
            for place in places(for: day) where !place.isBooking {
                ids.append(place.id)
            }
        }
        for place in wishlistPlaces where !place.isBooking {
            ids.append(place.id)
        }
        return ids
    }

    func isDayCollapsed(_ day: ItineraryDay) -> Bool {
        collapsedDayIds.contains(day.id)
    }

    func toggleDayCollapse(_ day: ItineraryDay) {
        if collapsedDayIds.contains(day.id) {
            collapsedDayIds.remove(day.id)
        } else {
            collapsedDayIds.insert(day.id)
        }
    }

    /// Primary line segment for day headers, e.g. `Day 1`.
    func dayHeaderDayLabel(for day: ItineraryDay) -> String {
        "Day \(day.dayNumber)"
    }

    /// Secondary segment, e.g. `Tue, Apr 21` (abbreviated weekday + month/day).
    func dayHeaderDateLabel(for day: ItineraryDay, timelineTimeZone: TimeZone) -> String {
        let date = day.date ?? dateForScheduledDay(day.dayNumber)
        return "\(date.dayOfWeekShort(timeZone: timelineTimeZone)), \(date.shortFormatted(timeZone: timelineTimeZone))"
    }

    var totalBookingsCount: Int {
        scheduledDays.reduce(0) { partial, day in
            partial + places(for: day).filter(\.isBooking).count
        }
    }

    func loadTripData() async {
        timelineLoadGeneration += 1
        let generation = timelineLoadGeneration
        let shouldShowLoading = scheduledDays.isEmpty && wishlistPlaces.isEmpty
        if shouldShowLoading {
            isLoading = true
        }
        defer {
            if shouldShowLoading, generation == timelineLoadGeneration {
                isLoading = false
            }
        }

        // Parallel fetch: trip_days + all trip_activities + all trip_bookings
        // in three concurrent queries, merged by day. Mirrors the web app's
        // fetchTripTimelineEnriched + tripDetailStore booking fetch pattern.
        let (days, fetched) = await dataService.fetchTripTimeline(for: trip.id)
        guard generation == timelineLoadGeneration else { return }
        let sorted = days.sorted { $0.dayNumber < $1.dayNumber }

        // `DataService` intentionally soft-fails network errors to empty
        // collections. During background realtime refreshes, preserving the
        // last known timeline is less disruptive than briefly blanking the
        // screen and invalidating any open Menu.
        if sorted.isEmpty && (!scheduledDays.isEmpty || !wishlistPlaces.isEmpty) {
            return
        }

        let nextScheduledDays = sorted.filter { !$0.isWishlist }
        let nextWishlistDayId = sorted.first(where: { $0.isWishlist })?.id
        let nextWishlistPlaces: [Place]
        if let wishlistDay = sorted.first(where: { $0.isWishlist }) {
            nextWishlistPlaces = fetched[wishlistDay.id] ?? []
        } else {
            nextWishlistPlaces = []
        }

        if scheduledDays != nextScheduledDays {
            scheduledDays = nextScheduledDays
        }
        if wishlistDayId != nextWishlistDayId {
            wishlistDayId = nextWishlistDayId
        }
        if placesByDayId != fetched {
            placesByDayId = fetched
        }
        if wishlistPlaces != nextWishlistPlaces {
            wishlistPlaces = nextWishlistPlaces
        }

        // Shortcut counts are independent from the activity/booking timeline.
        // Load them for the initial render, then refresh explicitly when the
        // Notes/Checklists screens close. This keeps realtime timeline events
        // from visually churning the pill row.
        if !hasLoadedShortcutCounts {
            await refreshHeroShortcutCounts()
        }
    }

    func refreshHeroShortcutCounts() async {
        shortcutCountsLoadGeneration += 1
        let generation = shortcutCountsLoadGeneration
        guard let counts = await dataService.tripHeroShortcutCounts(tripId: trip.id) else { return }
        guard generation == shortcutCountsLoadGeneration else { return }

        if checklistDoneCount != counts.checklistDone {
            checklistDoneCount = counts.checklistDone
        }
        if checklistTotalCount != counts.checklistTotal {
            checklistTotalCount = counts.checklistTotal
        }
        if noteCount != counts.noteCount {
            noteCount = counts.noteCount
        }
        hasLoadedShortcutCounts = true
    }

    func expandAll() {
        collapsedDayIds.removeAll()
        HapticManager.selection()
    }

    func collapseAll() {
        collapsedDayIds = Set(scheduledDays.map(\.id))
        HapticManager.selection()
    }

    /// Anchor date for a scheduled day (server `trip_days.date` when present,
    /// otherwise derived from `trip.startDate` + day number).
    func resolvedTimelineAnchorDate(for day: ItineraryDay) -> Date {
        day.date ?? dateForScheduledDay(day.dayNumber)
    }

    /// Places and bookings for the day section UI — expands each **hotel**
    /// into check-in / check-out rows when those dates match this day’s
    /// calendar (in `timelineTimeZone`), and appends “detached” hotel rows
    /// when check-in or check-out falls on this day but the booking lives on
    /// another itinerary day in the database.
    func timelineDisplayRows(for day: ItineraryDay, timelineTimeZone: TimeZone) -> [TripTimelineDisplayRow] {
        let anchor = resolvedTimelineAnchorDate(for: day)
        let dayPlaces = places(for: day)

        var nativeRows: [TripTimelineDisplayRow] = []
        for place in dayPlaces {
            if place.isBooking,
               place.bookingCategoryEnum == .hotel,
               case .hotel(let h) = place.bookingDetails {
                var splitRoles: [(HotelTimelineDisplayRole, String)] = []
                if TripTimelineRowCalendar.isSameCalendarDay(
                    hotelDate: h.checkInDate,
                    itineraryAnchor: anchor,
                    timelineTimeZone: timelineTimeZone
                ) {
                    splitRoles.append((.checkIn, "\(place.id.uuidString)-hotel-checkin"))
                }
                if TripTimelineRowCalendar.isSameCalendarDay(
                    hotelDate: h.checkOutDate,
                    itineraryAnchor: anchor,
                    timelineTimeZone: timelineTimeZone
                ) {
                    splitRoles.append((.checkOut, "\(place.id.uuidString)-hotel-checkout"))
                }
                if splitRoles.isEmpty {
                    nativeRows.append(TripTimelineDisplayRow(
                        id: "\(place.id.uuidString)-hotel-stay",
                        place: place,
                        hotelTimelineRole: nil
                    ))
                } else {
                    for (role, rowId) in splitRoles {
                        nativeRows.append(TripTimelineDisplayRow(id: rowId, place: place, hotelTimelineRole: role))
                    }
                }
            } else {
                nativeRows.append(TripTimelineDisplayRow(id: place.id.uuidString, place: place, hotelTimelineRole: nil))
            }
        }

        var seenIds = Set(nativeRows.map(\.id))
        var injected: [TripTimelineDisplayRow] = []
        for place in allScheduledPlaces() {
            guard place.isBooking,
                  place.bookingCategoryEnum == .hotel,
                  place.itineraryDayId != day.id,
                  case .hotel(let h) = place.bookingDetails else { continue }

            if TripTimelineRowCalendar.isSameCalendarDay(
                hotelDate: h.checkInDate,
                itineraryAnchor: anchor,
                timelineTimeZone: timelineTimeZone
            ) {
                let rowId = "\(place.id.uuidString)-hotel-checkin"
                if !seenIds.contains(rowId) {
                    injected.append(TripTimelineDisplayRow(id: rowId, place: place, hotelTimelineRole: .checkIn))
                    seenIds.insert(rowId)
                }
            }
            if TripTimelineRowCalendar.isSameCalendarDay(
                hotelDate: h.checkOutDate,
                itineraryAnchor: anchor,
                timelineTimeZone: timelineTimeZone
            ) {
                let rowId = "\(place.id.uuidString)-hotel-checkout"
                if !seenIds.contains(rowId) {
                    injected.append(TripTimelineDisplayRow(id: rowId, place: place, hotelTimelineRole: .checkOut))
                    seenIds.insert(rowId)
                }
            }
        }

        let combined = nativeRows + injected
        return combined.sorted { lhs, rhs in
            switch (lhs.timelineSortInstant, rhs.timelineSortInstant) {
            case let (l?, r?):
                if l != r { return l < r }
            case (nil, _?):
                return false
            case (_?, nil):
                return true
            case (nil, nil):
                break
            }
            if lhs.place.sortOrder != rhs.place.sortOrder {
                return lhs.place.sortOrder < rhs.place.sortOrder
            }
            if lhs.roleOrderingIndex != rhs.roleOrderingIndex {
                return lhs.roleOrderingIndex < rhs.roleOrderingIndex
            }
            return lhs.id < rhs.id
        }
    }

    func ongoingBookings(for day: ItineraryDay) -> [(place: Place, isFirstAppearance: Bool)] {
        guard let dayDate = day.date else { return [] }
        var ongoing: [(Place, Bool)] = []
        for otherDay in scheduledDays where otherDay.id != day.id {
            for place in places(for: otherDay) where place.isBooking {
                guard let details = place.bookingDetails else { continue }
                var spans = false
                switch details {
                case .hotel(let h):
                    if let checkIn = h.checkInDate, let checkOut = h.checkOutDate {
                        spans = checkIn < dayDate && checkOut > dayDate
                    }
                case .carRental(let c):
                    if let pickup = c.pickupTime, let dropoff = c.dropoffTime {
                        spans = pickup < dayDate && dropoff > dayDate
                    }
                default:
                    if let start = place.startTime, let end = place.endTime {
                        spans = start < dayDate && end > dayDate
                    }
                }
                if spans {
                    let bookingDayNumber = scheduledDays.first(where: { $0.id == place.itineraryDayId })?.dayNumber ?? 0
                    let isFirst = day.dayNumber == bookingDayNumber + 1
                    ongoing.append((place, isFirst))
                }
            }
        }
        return ongoing
    }

    private func dateForScheduledDay(_ dayNumber: Int) -> Date {
        guard dayNumber > 0 else { return trip.startDate }
        return Calendar.current.date(byAdding: .day, value: dayNumber - 1, to: trip.startDate) ?? trip.startDate
    }
}

// =============================================================================

