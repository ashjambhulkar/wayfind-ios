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
    private let dataService: MockDataService

    var trip: Trip
    var scheduledDays: [ItineraryDay] = []
    var wishlistPlaces: [Place] = []
    private(set) var wishlistDayId: UUID?
    var isLoading = false

    private var placesByDayId: [UUID: [Place]] = [:]
    private var collapsedDayIds: Set<UUID> = []

    init(trip: Trip, dataService: MockDataService) {
        self.trip = trip
        self.dataService = dataService
    }

    func places(for day: ItineraryDay) -> [Place] {
        placesByDayId[day.id] ?? []
    }

    func placesCount(for day: ItineraryDay) -> Int {
        places(for: day).count
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

    func dayStatusText(for day: ItineraryDay) -> String {
        let date = day.date ?? dateForScheduledDay(day.dayNumber)
        let weekday = date.dayOfWeekFull
        let monthDay = date.shortFormatted
        return "Day \(day.dayNumber) — \(weekday), \(monthDay)"
    }

    var totalBookingsCount: Int {
        scheduledDays.reduce(0) { partial, day in
            partial + places(for: day).filter(\.isBooking).count
        }
    }

    func loadTripData() async {
        isLoading = true
        defer { isLoading = false }

        let days = await dataService.fetchDays(for: trip.id)
        let sorted = days.sorted { $0.dayNumber < $1.dayNumber }
        scheduledDays = sorted.filter { !$0.isWishlist }
        wishlistDayId = sorted.first(where: { $0.isWishlist })?.id

        var nextPlaces: [UUID: [Place]] = [:]
        for day in sorted {
            nextPlaces[day.id] = await dataService.fetchPlaces(for: day.id)
        }
        placesByDayId = nextPlaces

        if let wishlistDay = sorted.first(where: { $0.isWishlist }) {
            wishlistPlaces = nextPlaces[wishlistDay.id] ?? []
        } else {
            wishlistPlaces = []
        }
    }

    func expandAll() {
        collapsedDayIds.removeAll()
        HapticManager.selection()
    }

    func collapseAll() {
        collapsedDayIds = Set(scheduledDays.map(\.id))
        HapticManager.selection()
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