//
//  MockDataService.swift
//  wayfind
//
//  Created by Ashish Jambhulkar on 4/2/26.
//

import Foundation
import Observation

@Observable
final class MockDataService {
    var trips: [Trip]
    var tripDays: [UUID: [ItineraryDay]]
    var dayPlaces: [UUID: [Place]]
    var parsedBookings: [ParsedBooking]

    init() {
        let built = Self.buildSampleData()
        trips = built.trips
        tripDays = built.tripDays
        dayPlaces = built.dayPlaces
        parsedBookings = built.parsedBookings
    }

    func fetchTrips() async -> [Trip] {
        #if DEBUG
        try? await Task.sleep(for: .milliseconds(500))
        #endif
        return trips.sorted { $0.startDate > $1.startDate }
    }

    func fetchDays(for tripId: UUID) async -> [ItineraryDay] {
        #if DEBUG
        try? await Task.sleep(for: .milliseconds(500))
        #endif
        return tripDays[tripId]?.sorted { $0.dayNumber < $1.dayNumber } ?? []
    }

    func fetchPlaces(for dayId: UUID) async -> [Place] {
        #if DEBUG
        try? await Task.sleep(for: .milliseconds(500))
        #endif
        return dayPlaces[dayId]?.sorted { $0.sortOrder < $1.sortOrder } ?? []
    }

    func fetchParsedBookings(for tripId: UUID) async -> [ParsedBooking] {
        parsedBookings.filter { $0.tripId == tripId }
    }

    func deleteTrip(id: UUID) async {
        trips.removeAll { $0.id == id }
        guard let days = tripDays.removeValue(forKey: id) else { return }
        for day in days {
            dayPlaces.removeValue(forKey: day.id)
        }
    }

    func addTrip(_ trip: Trip) async {
        trips.append(trip)
        if tripDays[trip.id] == nil {
            tripDays[trip.id] = []
        }
    }

    func addPlace(_ place: Place) async {
        var list = dayPlaces[place.itineraryDayId] ?? []
        list.append(place)
        dayPlaces[place.itineraryDayId] = list
    }

    func deletePlace(id: UUID) async {
        for key in dayPlaces.keys {
            dayPlaces[key]?.removeAll { $0.id == id }
        }
    }

    func updatePlace(_ place: Place) async {
        for key in dayPlaces.keys {
            if let index = dayPlaces[key]?.firstIndex(where: { $0.id == place.id }) {
                dayPlaces[key]?[index] = place
                return
            }
        }
    }

    func movePlace(placeId: UUID, toDayId: UUID) async {
        var movedPlace: Place?
        for key in dayPlaces.keys {
            if let index = dayPlaces[key]?.firstIndex(where: { $0.id == placeId }) {
                movedPlace = dayPlaces[key]?.remove(at: index)
                break
            }
        }
        guard var place = movedPlace else { return }
        place.itineraryDayId = toDayId
        let existingCount = dayPlaces[toDayId]?.count ?? 0
        place.sortOrder = existingCount
        var list = dayPlaces[toDayId] ?? []
        list.append(place)
        dayPlaces[toDayId] = list
    }

    func updateTrip(_ trip: Trip) async {
        if let index = trips.firstIndex(where: { $0.id == trip.id }) {
            trips[index] = trip
        }
    }

    func regenerateDays(for tripId: UUID, startDate: Date, endDate: Date) async {
        let calendar = Calendar.current
        let dayCount = (calendar.dateComponents([.day], from: startDate, to: endDate).day ?? 0) + 1
        guard let existingDays = tripDays[tripId] else { return }
        let wishlistDay = existingDays.first(where: { $0.dayNumber == 0 })
        let scheduled = existingDays.filter { !$0.isWishlist }

        var orphaned: [Place] = []
        for day in scheduled where day.dayNumber > dayCount {
            orphaned.append(contentsOf: dayPlaces[day.id] ?? [])
            dayPlaces.removeValue(forKey: day.id)
        }
        if let wId = wishlistDay?.id {
            var wishlist = dayPlaces[wId] ?? []
            for var place in orphaned {
                place.itineraryDayId = wId
                wishlist.append(place)
            }
            dayPlaces[wId] = wishlist
        }

        var newDays: [ItineraryDay] = []
        if let wd = wishlistDay { newDays.append(wd) }
        for dayNum in 1...dayCount {
            if let existing = scheduled.first(where: { $0.dayNumber == dayNum }) {
                newDays.append(existing)
            } else {
                newDays.append(ItineraryDay(
                    id: UUID(), tripId: tripId, dayNumber: dayNum,
                    date: calendar.date(byAdding: .day, value: dayNum - 1, to: startDate)
                ))
            }
        }
        tripDays[tripId] = newDays
    }

    private static func buildSampleData() -> (trips: [Trip], tripDays: [UUID: [ItineraryDay]], dayPlaces: [UUID: [Place]], parsedBookings: [ParsedBooking]) {
        let calendar = Calendar.current
        let now = Date()
        let todayStart = calendar.startOfDay(for: now)

        func dayOffset(_ offset: Int, from base: Date = todayStart) -> Date {
            calendar.date(byAdding: .day, value: offset, to: base) ?? base
        }

        func endOfCalendarDay(_ date: Date) -> Date {
            let start = calendar.startOfDay(for: date)
            return calendar.date(byAdding: DateComponents(day: 1, second: -1), to: start) ?? date
        }

        func time(on day: Date, hour: Int, minute: Int) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: calendar.startOfDay(for: day)) ?? day
        }

        let userId = UUID(uuidString: "6F1E8B2A-4C3D-5E6F-A7B8-9012345678AB")!

        let tripParisId = UUID(uuidString: "11111111-2222-3333-4444-555555550001")!
        let tripTokyoId = UUID(uuidString: "11111111-2222-3333-4444-555555550002")!
        let tripBarcelonaId = UUID(uuidString: "11111111-2222-3333-4444-555555550003")!

        let parisStart = dayOffset(-2)
        let parisEnd = endOfCalendarDay(dayOffset(5))

        let tripParis = Trip(
            id: tripParisId,
            userId: userId,
            title: "Trip to Paris",
            destination: "Paris, France",
            lat: 48.8566,
            lng: 2.3522,
            startDate: parisStart,
            endDate: parisEnd,
            coverImageUrl: nil,
            notes: nil,
            createdAt: dayOffset(-30)
        )

        let tokyoStart = dayOffset(12)
        let tokyoEnd = endOfCalendarDay(dayOffset(12 + 6))

        let tripTokyo = Trip(
            id: tripTokyoId,
            userId: userId,
            title: "Tokyo Adventure",
            destination: "Tokyo, Japan",
            lat: 35.6762,
            lng: 139.6503,
            startDate: tokyoStart,
            endDate: tokyoEnd,
            coverImageUrl: nil,
            notes: nil,
            createdAt: dayOffset(-14)
        )

        let barcelonaEnd = endOfCalendarDay(dayOffset(-20))
        let barcelonaStart = dayOffset(-25)

        let tripBarcelona = Trip(
            id: tripBarcelonaId,
            userId: userId,
            title: "Barcelona Summer",
            destination: "Barcelona, Spain",
            lat: nil,
            lng: nil,
            startDate: barcelonaStart,
            endDate: barcelonaEnd,
            coverImageUrl: nil,
            notes: nil,
            createdAt: dayOffset(-60)
        )

        var tripDaysMap: [UUID: [ItineraryDay]] = [:]
        var dayPlacesMap: [UUID: [Place]] = [:]

        let parisDay0 = UUID(uuidString: "21111111-2222-3333-4444-555555550000")!
        let parisDay1 = UUID(uuidString: "21111111-2222-3333-4444-555555550001")!
        let parisDay2 = UUID(uuidString: "21111111-2222-3333-4444-555555550002")!
        let parisDay3 = UUID(uuidString: "21111111-2222-3333-4444-555555550003")!
        let parisDay4 = UUID(uuidString: "21111111-2222-3333-4444-555555550004")!
        let parisDay5 = UUID(uuidString: "21111111-2222-3333-4444-555555550005")!
        let parisDay6 = UUID(uuidString: "21111111-2222-3333-4444-555555550006")!
        let parisDay7 = UUID(uuidString: "21111111-2222-3333-4444-555555550007")!
        let parisDay8 = UUID(uuidString: "21111111-2222-3333-4444-555555550008")!

        tripDaysMap[tripParisId] = [
            ItineraryDay(id: parisDay0, tripId: tripParisId, dayNumber: 0, date: parisStart),
            ItineraryDay(id: parisDay1, tripId: tripParisId, dayNumber: 1, date: dayOffset(0, from: parisStart)),
            ItineraryDay(id: parisDay2, tripId: tripParisId, dayNumber: 2, date: dayOffset(1, from: parisStart)),
            ItineraryDay(id: parisDay3, tripId: tripParisId, dayNumber: 3, date: dayOffset(2, from: parisStart)),
            ItineraryDay(id: parisDay4, tripId: tripParisId, dayNumber: 4, date: dayOffset(3, from: parisStart)),
            ItineraryDay(id: parisDay5, tripId: tripParisId, dayNumber: 5, date: dayOffset(4, from: parisStart)),
            ItineraryDay(id: parisDay6, tripId: tripParisId, dayNumber: 6, date: dayOffset(5, from: parisStart)),
            ItineraryDay(id: parisDay7, tripId: tripParisId, dayNumber: 7, date: dayOffset(6, from: parisStart)),
            ItineraryDay(id: parisDay8, tripId: tripParisId, dayNumber: 8, date: dayOffset(7, from: parisStart)),
        ]

        dayPlacesMap[parisDay0] = [
            Place(
                id: UUID(uuidString: "31111111-2222-3333-4444-555555550001")!,
                itineraryDayId: parisDay0,
                name: "Sainte-Chapelle",
                address: "8 Bd du Palais, 75001 Paris",
                lat: 48.8565,
                lng: 2.3450,
                category: "attraction",
                notes: nil,
                sortOrder: 0,
                startTime: nil,
                endTime: nil,
                isBooking: false,
                bookingType: nil,
                confirmationNumber: nil,
                bookingDetails: nil
            ),
            Place(
                id: UUID(uuidString: "31111111-2222-3333-4444-555555550002")!,
                itineraryDayId: parisDay0,
                name: "Shakespeare & Co",
                address: "37 Rue de la Bûcherie, 75005 Paris",
                lat: 48.8506,
                lng: 2.3470,
                category: "shopping",
                notes: nil,
                sortOrder: 1,
                startTime: nil,
                endTime: nil,
                isBooking: false,
                bookingType: nil,
                confirmationNumber: nil,
                bookingDetails: nil
            ),
        ]

        let flightDay = dayOffset(0, from: parisStart)
        let flightDeparture = time(on: flightDay, hour: 8, minute: 30)
        let flightArrival = time(on: flightDay, hour: 21, minute: 15)

        let flightDetails = FlightDetails(
            airline: "American Airlines",
            flightNumber: "1234",
            departureAirport: "JFK",
            arrivalAirport: "CDG",
            departureTime: flightDeparture,
            arrivalTime: flightArrival,
            terminal: "8",
            gate: "B22",
            seat: "12A"
        )

        dayPlacesMap[parisDay1] = [
            Place(
                id: UUID(uuidString: "31111111-2222-3333-4444-555555550010")!,
                itineraryDayId: parisDay1,
                name: "AA 1234 · JFK to CDG",
                address: "John F. Kennedy International Airport",
                lat: 40.6413,
                lng: -73.7781,
                category: "transport",
                notes: nil,
                sortOrder: 0,
                startTime: flightDeparture,
                endTime: flightArrival,
                isBooking: true,
                bookingType: BookingCategory.flight.rawValue,
                confirmationNumber: "ABC123456",
                bookingDetails: .flight(flightDetails)
            ),
            Place(
                id: UUID(uuidString: "31111111-2222-3333-4444-555555550011")!,
                itineraryDayId: parisDay1,
                name: "Le Marais Hotel",
                address: "12 Rue des Rosiers, 75004 Paris",
                lat: 48.8569,
                lng: 2.3622,
                category: "hotel",
                notes: nil,
                sortOrder: 1,
                startTime: nil,
                endTime: nil,
                isBooking: true,
                bookingType: BookingCategory.hotel.rawValue,
                confirmationNumber: "LMH-778899",
                bookingDetails: .hotel(
                    HotelDetails(
                        checkInDate: dayOffset(0, from: parisStart),
                        checkInTime: "3:00 PM",
                        checkOutDate: dayOffset(5, from: parisStart),
                        checkOutTime: "11:00 AM",
                        roomType: "Deluxe Queen",
                        nights: 5
                    )
                )
            ),
        ]

        let day2Date = dayOffset(1, from: parisStart)
        dayPlacesMap[parisDay2] = [
            Place(
                id: UUID(uuidString: "31111111-2222-3333-4444-555555550020")!,
                itineraryDayId: parisDay2,
                name: "Eiffel Tower",
                address: "Champ de Mars, 5 Av. Anatole France, 75007 Paris",
                lat: 48.8584,
                lng: 2.2945,
                category: "attraction",
                notes: nil,
                sortOrder: 0,
                startTime: time(on: day2Date, hour: 9, minute: 0),
                endTime: time(on: day2Date, hour: 11, minute: 30),
                isBooking: false,
                bookingType: nil,
                confirmationNumber: nil,
                bookingDetails: nil
            ),
            Place(
                id: UUID(uuidString: "31111111-2222-3333-4444-555555550021")!,
                itineraryDayId: parisDay2,
                name: "Le Petit Cler",
                address: "29 Rue Cler, 75007 Paris",
                lat: 48.8570,
                lng: 2.3090,
                category: "restaurant",
                notes: nil,
                sortOrder: 1,
                startTime: time(on: day2Date, hour: 12, minute: 15),
                endTime: time(on: day2Date, hour: 13, minute: 30),
                isBooking: false,
                bookingType: nil,
                confirmationNumber: nil,
                bookingDetails: nil
            ),
            Place(
                id: UUID(uuidString: "31111111-2222-3333-4444-555555550022")!,
                itineraryDayId: parisDay2,
                name: "Musée d'Orsay",
                address: "1 Rue de la Légion d'Honneur, 75007 Paris",
                lat: 48.8600,
                lng: 2.3266,
                category: "attraction",
                notes: nil,
                sortOrder: 2,
                startTime: time(on: day2Date, hour: 14, minute: 30),
                endTime: time(on: day2Date, hour: 17, minute: 0),
                isBooking: false,
                bookingType: nil,
                confirmationNumber: nil,
                bookingDetails: nil
            ),
        ]

        let day3Date = dayOffset(2, from: parisStart)
        let dinnerTime = time(on: day3Date, hour: 20, minute: 0)

        dayPlacesMap[parisDay3] = [
            Place(
                id: UUID(uuidString: "31111111-2222-3333-4444-555555550030")!,
                itineraryDayId: parisDay3,
                name: "Louvre Museum",
                address: "Rue de Rivoli, 75001 Paris",
                lat: 48.8606,
                lng: 2.3376,
                category: "attraction",
                notes: nil,
                sortOrder: 0,
                startTime: time(on: day3Date, hour: 10, minute: 0),
                endTime: time(on: day3Date, hour: 13, minute: 0),
                isBooking: false,
                bookingType: nil,
                confirmationNumber: nil,
                bookingDetails: nil
            ),
            Place(
                id: UUID(uuidString: "31111111-2222-3333-4444-555555550031")!,
                itineraryDayId: parisDay3,
                name: "Septime",
                address: "80 Rue de Charonne, 75011 Paris",
                lat: 48.8534,
                lng: 2.3844,
                category: "restaurant",
                notes: "Dinner reservation",
                sortOrder: 1,
                startTime: dinnerTime,
                endTime: nil,
                isBooking: true,
                bookingType: BookingCategory.restaurant.rawValue,
                confirmationNumber: "SEP-4412",
                bookingDetails: .restaurant(
                    RestaurantDetails(
                        reservationTime: dinnerTime,
                        partySize: 2
                    )
                )
            ),
        ]

        tripDaysMap[tripTokyoId] = []
        tripDaysMap[tripBarcelonaId] = []

        let tripLondonId = UUID(uuidString: "11111111-2222-3333-4444-555555550004")!
        let tripLondon = Trip(
            id: tripLondonId,
            userId: userId,
            title: "London Calling",
            destination: "London, UK",
            lat: 51.5074,
            lng: -0.1278,
            startDate: dayOffset(20),
            endDate: endOfCalendarDay(dayOffset(25)),
            coverImageUrl: nil,
            notes: nil,
            createdAt: dayOffset(-7)
        )
        tripDaysMap[tripLondonId] = []

        let tripRomeId = UUID(uuidString: "11111111-2222-3333-4444-555555550005")!
        let tripRome = Trip(
            id: tripRomeId,
            userId: userId,
            title: "Ancient Rome",
            destination: "Rome, Italy",
            lat: nil,
            lng: nil,
            startDate: dayOffset(-40),
            endDate: endOfCalendarDay(dayOffset(-35)),
            coverImageUrl: nil,
            notes: nil,
            createdAt: dayOffset(-50)
        )
        tripDaysMap[tripRomeId] = []

        let parsedSample1 = ParsedBooking(
            id: UUID(uuidString: "41111111-2222-3333-4444-555555550001")!,
            userId: userId,
            tripId: tripParisId,
            status: .parsed,
            parsedData: [
                "type": "flight",
                "airline": "Air France",
                "number": "AF 789",
                "from": "CDG",
                "to": "NCE",
            ],
            createdAt: dayOffset(-1)
        )
        let parsedSample2 = ParsedBooking(
            id: UUID(uuidString: "41111111-2222-3333-4444-555555550002")!,
            userId: userId,
            tripId: tripParisId,
            status: .pending,
            parsedData: nil,
            createdAt: dayOffset(-2)
        )

        return (
            trips: [tripParis, tripTokyo, tripBarcelona, tripLondon, tripRome],
            tripDays: tripDaysMap,
            dayPlaces: dayPlacesMap,
            parsedBookings: [parsedSample1, parsedSample2]
        )
    }
}
