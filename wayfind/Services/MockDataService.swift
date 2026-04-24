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

    func fetchProfileAggregateStats() async -> ProfileAggregateStats {
        let calendar = Calendar.current
        let inputs: [ProfileTripBucketInput] = trips.map { trip in
            let startISO = SupabaseModelMapping.calendarDateOnlyString(from: trip.startDate, calendar: calendar)
            let endISO = SupabaseModelMapping.calendarDateOnlyString(from: trip.endDate, calendar: calendar)
            let status =
                trip.databaseStatus
                ?? SupabaseModelMapping.inferTripStatus(startDate: trip.startDate, endDate: trip.endDate, calendar: calendar)
            return ProfileTripBucketInput(
                id: trip.id,
                startDateISO: startISO,
                endDateISO: endISO,
                status: status,
                isActive: trip.isMarkedActiveOnServer
            )
        }
        var placeIds = Set<String>()
        for places in dayPlaces.values {
            for place in places {
                let trimmed = place.googlePlaceId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !trimmed.isEmpty { placeIds.insert(trimmed) }
            }
        }
        return ProfileAggregateStats(
            tripCount: trips.count,
            upcomingOrActiveCount: ProfileTripBucketing.countUpcomingOrActiveTrips(inputs),
            distinctPlaceCount: placeIds.count,
            importedBookingCount: parsedBookings.count
        )
    }

    func deleteTrip(id: UUID) async {
        trips.removeAll { $0.id == id }
        guard let days = tripDays.removeValue(forKey: id) else { return }
        for day in days {
            dayPlaces.removeValue(forKey: day.id)
        }
    }

    @discardableResult
    func addTrip(_ trip: Trip) async -> Trip {
        trips.append(trip)
        if tripDays[trip.id] == nil {
            tripDays[trip.id] = []
        }
        return trip
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

    private var mockTripNotes: [UUID: [TripNote]] = [:]

    func listTripNotes(tripId: UUID) async -> [TripNote] {
        mockTripNotes[tripId] ?? []
    }

    func createTripNote(tripId: UUID) async -> TripNote? {
        guard let trip = trips.first(where: { $0.id == tripId }) else { return nil }
        let note = TripNote(
            id: UUID(),
            tripId: tripId,
            userId: trip.userId,
            title: "",
            body: "",
            createdAt: Date(),
            updatedAt: Date()
        )
        var list = mockTripNotes[tripId] ?? []
        list.insert(note, at: 0)
        mockTripNotes[tripId] = list
        return note
    }

    func updateTripNote(noteId: UUID, title: String, body: String) async {
        for tid in mockTripNotes.keys {
            guard var list = mockTripNotes[tid] else { continue }
            if let i = list.firstIndex(where: { $0.id == noteId }) {
                list[i].title = title
                list[i].body = body
                list[i].updatedAt = Date()
                mockTripNotes[tid] = list
                return
            }
        }
    }

    func deleteTripNote(noteId: UUID) async {
        for tid in mockTripNotes.keys {
            guard var list = mockTripNotes[tid] else { continue }
            list.removeAll { $0.id == noteId }
            mockTripNotes[tid] = list
        }
    }

    func listTemplateTripChecklistsWithItems(tripId: UUID) async -> [TripChecklistWithItems] {
        let uid = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

        func makeItem(_ id: String, _ checklistId: UUID, _ title: String, _ isDone: Bool, _ order: Int) -> TripChecklistItem {
            TripChecklistItem(id: UUID(uuidString: id)!, checklistId: checklistId, title: title, isDone: isDone, sortOrder: order)
        }

        let packingId = UUID(uuidString: "60000001-0000-0000-0000-000000000001")!
        let todoId    = UUID(uuidString: "60000002-0000-0000-0000-000000000001")!
        let docsId    = UUID(uuidString: "60000003-0000-0000-0000-000000000001")!

        let packing = TripChecklistWithItems(
            id: packingId, tripId: tripId, templateKey: "packing", title: "Packing", sortOrder: 0,
            items: [
                makeItem("61000001-0000-0000-0000-000000000001", packingId, "Passport", true, 0),
                makeItem("61000002-0000-0000-0000-000000000001", packingId, "Flight tickets printed", true, 1),
                makeItem("61000003-0000-0000-0000-000000000001", packingId, "Travel adapter", true, 2),
                makeItem("61000004-0000-0000-0000-000000000001", packingId, "Sunscreen SPF 50", false, 3),
                makeItem("61000005-0000-0000-0000-000000000001", packingId, "Comfortable walking shoes", true, 4),
                makeItem("61000006-0000-0000-0000-000000000001", packingId, "Rain jacket", false, 5),
                makeItem("61000007-0000-0000-0000-000000000001", packingId, "Camera + charger", false, 6),
                makeItem("61000008-0000-0000-0000-000000000001", packingId, "Medication & first aid kit", false, 7),
            ]
        )

        let todo = TripChecklistWithItems(
            id: todoId, tripId: tripId, templateKey: "todo", title: "To-Do", sortOrder: 1,
            items: [
                makeItem("62000001-0000-0000-0000-000000000001", todoId, "Book airport transfer", true, 0),
                makeItem("62000002-0000-0000-0000-000000000001", todoId, "Download offline maps", false, 1),
                makeItem("62000003-0000-0000-0000-000000000001", todoId, "Notify credit card of travel", true, 2),
                makeItem("62000004-0000-0000-0000-000000000001", todoId, "Check-in online 24hr before", false, 3),
                makeItem("62000005-0000-0000-0000-000000000001", todoId, "Get local SIM or eSIM", false, 4),
            ]
        )

        let documents = TripChecklistWithItems(
            id: docsId, tripId: tripId, templateKey: "documents", title: "Documents", sortOrder: 2,
            items: [
                makeItem("63000001-0000-0000-0000-000000000001", docsId, "Passport (valid 6+ months)", true, 0),
                makeItem("63000002-0000-0000-0000-000000000001", docsId, "Hotel confirmations", true, 1),
                makeItem("63000003-0000-0000-0000-000000000001", docsId, "Travel insurance documents", false, 2),
                makeItem("63000004-0000-0000-0000-000000000001", docsId, "Vaccination records", false, 3),
            ]
        )

        _ = uid
        return [packing, todo, documents]
    }

    func setChecklistItemDone(itemId: UUID, isDone: Bool) async {
        _ = itemId
        _ = isDone
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

        func tripServerSync(start: Date, end: Date) -> (status: String, isActive: Bool) {
            let status = SupabaseModelMapping.inferTripStatus(startDate: start, endDate: end, calendar: calendar)
            let isActive = SupabaseModelMapping.isTripActive(startDate: start, endDate: end, calendar: calendar)
            return (status, isActive)
        }

        let userId = UUID(uuidString: "6F1E8B2A-4C3D-5E6F-A7B8-9012345678AB")!

        let tripParisId = UUID(uuidString: "11111111-2222-3333-4444-555555550001")!
        let tripTokyoId = UUID(uuidString: "11111111-2222-3333-4444-555555550002")!
        let tripBarcelonaId = UUID(uuidString: "11111111-2222-3333-4444-555555550003")!

        let parisStart = dayOffset(-2)
        let parisEnd = endOfCalendarDay(dayOffset(5))
        let parisSync = tripServerSync(start: parisStart, end: parisEnd)

        let tripParis = Trip(
            id: tripParisId,
            userId: userId,
            title: "Trip to Paris",
            destination: "Paris, France",
            lat: 48.8566,
            lng: 2.3522,
            startDate: parisStart,
            endDate: parisEnd,
            coverImageUrl: "https://images.unsplash.com/photo-1502602898657-3e91760cbb34?w=800&q=80",
            notes: nil,
            createdAt: dayOffset(-30),
            updatedAt: dayOffset(-2),
            databaseStatus: parisSync.status,
            isMarkedActiveOnServer: parisSync.isActive
        )

        let tokyoStart = dayOffset(12)
        let tokyoEnd = endOfCalendarDay(dayOffset(12 + 6))
        let tokyoSync = tripServerSync(start: tokyoStart, end: tokyoEnd)

        let tripTokyo = Trip(
            id: tripTokyoId,
            userId: userId,
            title: "Tokyo Adventure",
            destination: "Tokyo, Japan",
            lat: 35.6762,
            lng: 139.6503,
            startDate: tokyoStart,
            endDate: tokyoEnd,
            coverImageUrl: "https://images.unsplash.com/photo-1540959733332-eab4deabeeaf?w=800&q=80",
            notes: nil,
            createdAt: dayOffset(-14),
            updatedAt: dayOffset(-10),
            databaseStatus: tokyoSync.status,
            isMarkedActiveOnServer: tokyoSync.isActive
        )

        let barcelonaEnd = endOfCalendarDay(dayOffset(-20))
        let barcelonaStart = dayOffset(-25)
        let barcelonaSync = tripServerSync(start: barcelonaStart, end: barcelonaEnd)

        let tripBarcelona = Trip(
            id: tripBarcelonaId,
            userId: userId,
            title: "Barcelona Summer",
            destination: "Barcelona, Spain",
            lat: 41.3874,
            lng: 2.1686,
            startDate: barcelonaStart,
            endDate: barcelonaEnd,
            coverImageUrl: "https://images.unsplash.com/photo-1583422409516-2895a77efded?w=800&q=80",
            notes: nil,
            createdAt: dayOffset(-60),
            updatedAt: dayOffset(-58),
            databaseStatus: barcelonaSync.status,
            isMarkedActiveOnServer: barcelonaSync.isActive
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
                lat: 48.8584, lng: 2.2945, category: "attraction", notes: nil, sortOrder: 0,
                startTime: time(on: day2Date, hour: 9, minute: 0),
                endTime: time(on: day2Date, hour: 11, minute: 30),
                isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil,
                heroImageUrl: "https://images.unsplash.com/photo-1509439581779-6298f75bf6e5?w=800&q=80",
                rating: 4.7, userRatingsTotal: 287_321, priceLevel: 2,
                website: "https://www.toureiffel.paris",
                isOpenNow: true, openingHoursText: "Open · Closes 11:45 PM",
                aiSummary: "The Eiffel Tower is Paris's most iconic landmark — a 330-metre iron masterpiece that transforms from a bold silhouette at dawn to a sparkling beacon after dark. Built in 1889, it still manages to astonish even jaded travellers.",
                whyGo: ["Best panoramic views of Paris from the summit", "Magical light show every hour after dark", "Instant mood-lifter — even seeing it from afar feels special"],
                knowBeforeYouGo: ["Book summit tickets weeks ahead — same-day queues are brutal", "Arrive at 9 AM sharp to beat the crowds", "Stairs are open to the 2nd floor if you want the workout"],
                reviewsTags: ["Iconic", "Must-see", "Romantic", "Stunning views"],
                durationMinutes: 150
            ),
            Place(
                id: UUID(uuidString: "31111111-2222-3333-4444-555555550021")!,
                itineraryDayId: parisDay2,
                name: "Le Petit Cler",
                address: "29 Rue Cler, 75007 Paris",
                lat: 48.8570, lng: 2.3090, category: "restaurant", notes: nil, sortOrder: 1,
                startTime: time(on: day2Date, hour: 12, minute: 15),
                endTime: time(on: day2Date, hour: 13, minute: 30),
                isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil,
                heroImageUrl: "https://images.unsplash.com/photo-1414235077428-338989a2e8c0?w=800&q=80",
                rating: 4.4, userRatingsTotal: 2_891, priceLevel: 2,
                isOpenNow: true, openingHoursText: "Open · Closes 10:30 PM",
                aiSummary: "A beloved neighbourhood bistro on the famous Rue Cler market street. Classic zinc bar, checked tablecloths, and a chalkboard menu that changes daily. The kind of lunch spot Parisians actually go to.",
                whyGo: ["Authentic Parisian bistro atmosphere without the tourist mark-up", "Steps from the Eiffel Tower — perfect midday break", "Try the croque monsieur and a glass of Bordeaux"],
                knowBeforeYouGo: ["No reservations for lunch — arrive by 12:15 for a table", "Cash preferred, card accepted", "Street market on Rue Cler is worth a wander before eating"],
                reviewsTags: ["Authentic", "Neighbourhood gem", "Great value", "Charming"],
                durationMinutes: 75
            ),
            Place(
                id: UUID(uuidString: "31111111-2222-3333-4444-555555550022")!,
                itineraryDayId: parisDay2,
                name: "Musée d'Orsay",
                address: "1 Rue de la Légion d'Honneur, 75007 Paris",
                lat: 48.8600, lng: 2.3266, category: "attraction", notes: nil, sortOrder: 2,
                startTime: time(on: day2Date, hour: 14, minute: 30),
                endTime: time(on: day2Date, hour: 17, minute: 0),
                isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil,
                heroImageUrl: "https://images.unsplash.com/photo-1541961017774-22349e4a1262?w=800&q=80",
                rating: 4.8, userRatingsTotal: 94_210, priceLevel: 2,
                website: "https://www.musee-orsay.fr",
                isOpenNow: true, openingHoursText: "Open · Closes 6:00 PM",
                aiSummary: "Housed in a stunning Beaux-Arts railway station, the Musée d'Orsay holds the world's greatest collection of Impressionist art. Monet's water lilies, Renoir's dancing figures, Van Gogh's self-portraits — all in one breathtaking building.",
                whyGo: ["World's finest Impressionist collection in one place", "The building itself is a work of art — shoot from the clock", "Much less crowded than the Louvre, far more rewarding"],
                knowBeforeYouGo: ["Free entry on the first Sunday of every month", "The 5th floor is where the Impressionist masterpieces are", "Book tickets online — walk-up queues stretch 45 min"],
                reviewsTags: ["World-class", "Less crowded than Louvre", "Beautiful building", "Art lovers"],
                durationMinutes: 150
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
                lat: 48.8606, lng: 2.3376, category: "attraction", notes: nil, sortOrder: 0,
                startTime: time(on: day3Date, hour: 10, minute: 0),
                endTime: time(on: day3Date, hour: 13, minute: 0),
                isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil,
                heroImageUrl: "https://images.unsplash.com/photo-1499426600726-7484f4e5c1f5?w=800&q=80",
                rating: 4.7, userRatingsTotal: 320_442, priceLevel: 2,
                website: "https://www.louvre.fr",
                isOpenNow: true, openingHoursText: "Open · Closes 6:00 PM",
                aiSummary: "The world's most visited museum and a historic monument in itself. Home to Leonardo da Vinci's Mona Lisa, the Venus de Milo, and 35,000 other works spanning 9,000 years of human civilisation. A full day wouldn't cover it — plan ruthlessly.",
                whyGo: ["The Mona Lisa and Venus de Milo in person — genuinely moves people", "The Denon Wing alone is worth the trip", "The glass pyramid at sunset is one of Paris's most photographic moments"],
                knowBeforeYouGo: ["3 hours is the minimum — pick 2 wings and focus", "Mona Lisa room is packed by 11 AM, go straight there at opening", "EU residents under 26 enter free"],
                reviewsTags: ["World-class", "Overwhelming", "Iconic", "Plan ahead"],
                durationMinutes: 180
            ),
            Place(
                id: UUID(uuidString: "31111111-2222-3333-4444-555555550031")!,
                itineraryDayId: parisDay3,
                name: "Septime",
                address: "80 Rue de Charonne, 75011 Paris",
                lat: 48.8534, lng: 2.3844, category: "restaurant", notes: "Dinner reservation",
                sortOrder: 1, startTime: dinnerTime, endTime: nil,
                isBooking: true, bookingType: BookingCategory.restaurant.rawValue,
                confirmationNumber: "SEP-4412",
                bookingDetails: .restaurant(RestaurantDetails(reservationTime: dinnerTime, partySize: 2)),
                heroImageUrl: "https://images.unsplash.com/photo-1600891964599-f61ba0e24092?w=800&q=80",
                rating: 4.6, userRatingsTotal: 1_243, priceLevel: 3,
                website: "https://www.septime-charonne.fr",
                isOpenNow: true, openingHoursText: "Open · Closes 11:00 PM",
                aiSummary: "One of Paris's most celebrated neo-bistros. Bertrand Grébaut's tasting menus balance modern French technique with seasonal produce — Michelin-starred but never stuffy. A table here feels like a genuine privilege.",
                whyGo: ["Michelin-starred cooking that doesn't feel intimidating", "Seasonal tasting menu changes weekly — always a discovery", "The natural wine list is outstanding and fairly priced"],
                knowBeforeYouGo: ["Reservations open 30 days in advance — book immediately", "Smart casual dress code expected", "Full tasting menu runs ~3 hours — don't rush the evening"],
                reviewsTags: ["Michelin star", "Romantic", "Special occasion", "Outstanding wine"],
                durationMinutes: 180
            ),
        ]

        // ── Paris Days 4-8 ────────────────────────────────────────────────────

        let day4Date = dayOffset(3, from: parisStart)
        dayPlacesMap[parisDay4] = [
            Place(id: UUID(uuidString: "31111111-2222-3333-4444-555555550040")!, itineraryDayId: parisDay4, name: "Sacré-Cœur Basilica", address: "35 Rue du Chevalier de la Barre, 75018 Paris", lat: 48.8867, lng: 2.3431, category: PlaceCategory.attraction.rawValue, notes: nil, sortOrder: 0, startTime: time(on: day4Date, hour: 10, minute: 0), endTime: time(on: day4Date, hour: 11, minute: 30), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "31111111-2222-3333-4444-555555550041")!, itineraryDayId: parisDay4, name: "Place du Tertre", address: "Place du Tertre, 75018 Paris", lat: 48.8866, lng: 2.3407, category: PlaceCategory.attraction.rawValue, notes: nil, sortOrder: 1, startTime: time(on: day4Date, hour: 11, minute: 45), endTime: time(on: day4Date, hour: 13, minute: 0), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "31111111-2222-3333-4444-555555550042")!, itineraryDayId: parisDay4, name: "Le Relais de la Butte", address: "12 Rue Ravignan, 75018 Paris", lat: 48.8845, lng: 2.3398, category: PlaceCategory.restaurant.rawValue, notes: nil, sortOrder: 2, startTime: time(on: day4Date, hour: 13, minute: 15), endTime: time(on: day4Date, hour: 14, minute: 30), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "31111111-2222-3333-4444-555555550043")!, itineraryDayId: parisDay4, name: "Moulin Rouge", address: "82 Bd de Clichy, 75018 Paris", lat: 48.8841, lng: 2.3323, category: PlaceCategory.nightlife.rawValue, notes: nil, sortOrder: 3, startTime: time(on: day4Date, hour: 21, minute: 0), endTime: time(on: day4Date, hour: 23, minute: 0), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
        ]

        let day5Date = dayOffset(4, from: parisStart)
        dayPlacesMap[parisDay5] = [
            Place(id: UUID(uuidString: "31111111-2222-3333-4444-555555550050")!, itineraryDayId: parisDay5, name: "Palace of Versailles", address: "Place d'Armes, 78000 Versailles", lat: 48.8049, lng: 2.1204, category: PlaceCategory.attraction.rawValue, notes: "Book tickets in advance", sortOrder: 0, startTime: time(on: day5Date, hour: 9, minute: 30), endTime: time(on: day5Date, hour: 13, minute: 0), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "31111111-2222-3333-4444-555555550051")!, itineraryDayId: parisDay5, name: "Gardens of Versailles", address: "78000 Versailles", lat: 48.8045, lng: 2.1072, category: PlaceCategory.nature.rawValue, notes: nil, sortOrder: 1, startTime: time(on: day5Date, hour: 13, minute: 15), endTime: time(on: day5Date, hour: 15, minute: 0), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "31111111-2222-3333-4444-555555550052")!, itineraryDayId: parisDay5, name: "La Flottille", address: "Lac des Suisses, 78000 Versailles", lat: 48.7998, lng: 2.1143, category: PlaceCategory.restaurant.rawValue, notes: nil, sortOrder: 2, startTime: time(on: day5Date, hour: 15, minute: 30), endTime: time(on: day5Date, hour: 16, minute: 45), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
        ]

        let day6Date = dayOffset(5, from: parisStart)
        dayPlacesMap[parisDay6] = [
            Place(id: UUID(uuidString: "31111111-2222-3333-4444-555555550060")!, itineraryDayId: parisDay6, name: "Centre Pompidou", address: "Place Georges-Pompidou, 75004 Paris", lat: 48.8607, lng: 2.3521, category: PlaceCategory.attraction.rawValue, notes: nil, sortOrder: 0, startTime: time(on: day6Date, hour: 10, minute: 0), endTime: time(on: day6Date, hour: 12, minute: 30), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "31111111-2222-3333-4444-555555550061")!, itineraryDayId: parisDay6, name: "Musée Picasso Paris", address: "5 Rue de Thorigny, 75003 Paris", lat: 48.8594, lng: 2.3623, category: PlaceCategory.attraction.rawValue, notes: nil, sortOrder: 1, startTime: time(on: day6Date, hour: 13, minute: 30), endTime: time(on: day6Date, hour: 15, minute: 30), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "31111111-2222-3333-4444-555555550062")!, itineraryDayId: parisDay6, name: "L'As du Fallafel", address: "34 Rue des Rosiers, 75004 Paris", lat: 48.8576, lng: 2.3560, category: PlaceCategory.restaurant.rawValue, notes: nil, sortOrder: 2, startTime: time(on: day6Date, hour: 12, minute: 0), endTime: time(on: day6Date, hour: 12, minute: 45), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "31111111-2222-3333-4444-555555550063")!, itineraryDayId: parisDay6, name: "Marché des Enfants Rouges", address: "39 Rue de Bretagne, 75003 Paris", lat: 48.8622, lng: 2.3605, category: PlaceCategory.shopping.rawValue, notes: nil, sortOrder: 3, startTime: time(on: day6Date, hour: 16, minute: 0), endTime: time(on: day6Date, hour: 17, minute: 30), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
        ]

        let day7Date = dayOffset(6, from: parisStart)
        dayPlacesMap[parisDay7] = [
            Place(id: UUID(uuidString: "31111111-2222-3333-4444-555555550070")!, itineraryDayId: parisDay7, name: "Seine River Cruise", address: "Port de la Conférence, 75008 Paris", lat: 48.8647, lng: 2.3097, category: PlaceCategory.attraction.rawValue, notes: nil, sortOrder: 0, startTime: time(on: day7Date, hour: 10, minute: 0), endTime: time(on: day7Date, hour: 11, minute: 15), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "31111111-2222-3333-4444-555555550071")!, itineraryDayId: parisDay7, name: "Notre-Dame Cathedral", address: "6 Parvis Notre-Dame, 75004 Paris", lat: 48.8530, lng: 2.3499, category: PlaceCategory.attraction.rawValue, notes: nil, sortOrder: 1, startTime: time(on: day7Date, hour: 12, minute: 0), endTime: time(on: day7Date, hour: 13, minute: 30), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "31111111-2222-3333-4444-555555550072")!, itineraryDayId: parisDay7, name: "Berthillon", address: "29-31 Rue Saint-Louis en l'Île, 75004 Paris", lat: 48.8510, lng: 2.3560, category: PlaceCategory.restaurant.rawValue, notes: nil, sortOrder: 2, startTime: time(on: day7Date, hour: 14, minute: 0), endTime: time(on: day7Date, hour: 14, minute: 45), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "31111111-2222-3333-4444-555555550073")!, itineraryDayId: parisDay7, name: "Île Saint-Louis Stroll", address: "Île Saint-Louis, 75004 Paris", lat: 48.8508, lng: 2.3565, category: PlaceCategory.nature.rawValue, notes: nil, sortOrder: 3, startTime: time(on: day7Date, hour: 15, minute: 0), endTime: time(on: day7Date, hour: 16, minute: 30), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
        ]

        let day8Date = dayOffset(7, from: parisStart)
        let returnFlightDep = time(on: day8Date, hour: 14, minute: 0)
        let returnFlightArr = time(on: day8Date, hour: 16, minute: 45)
        dayPlacesMap[parisDay8] = [
            Place(id: UUID(uuidString: "31111111-2222-3333-4444-555555550080")!, itineraryDayId: parisDay8, name: "AF 12 · CDG to JFK", address: "Charles de Gaulle Airport, 95700 Roissy-en-France", lat: 49.0097, lng: 2.5479, category: PlaceCategory.transport.rawValue, notes: nil, sortOrder: 0, startTime: returnFlightDep, endTime: returnFlightArr, isBooking: true, bookingType: BookingCategory.flight.rawValue, confirmationNumber: "AF12CDG", bookingDetails: .flight(FlightDetails(airline: "Air France", flightNumber: "12", departureAirport: "CDG", arrivalAirport: "JFK", departureTime: returnFlightDep, arrivalTime: returnFlightArr, terminal: "2E", gate: "K42", seat: "14C"))),
        ]

        // ── Tokyo ─────────────────────────────────────────────────────────────

        let tokyoDay0 = UUID(uuidString: "22222222-2222-3333-4444-555555550000")!
        let tokyoDay1 = UUID(uuidString: "22222222-2222-3333-4444-555555550001")!
        let tokyoDay2 = UUID(uuidString: "22222222-2222-3333-4444-555555550002")!
        let tokyoDay3 = UUID(uuidString: "22222222-2222-3333-4444-555555550003")!
        let tokyoDay4 = UUID(uuidString: "22222222-2222-3333-4444-555555550004")!
        let tokyoDay5 = UUID(uuidString: "22222222-2222-3333-4444-555555550005")!
        let tokyoDay6 = UUID(uuidString: "22222222-2222-3333-4444-555555550006")!
        let tokyoDay7 = UUID(uuidString: "22222222-2222-3333-4444-555555550007")!

        tripDaysMap[tripTokyoId] = [
            ItineraryDay(id: tokyoDay0, tripId: tripTokyoId, dayNumber: 0, date: tokyoStart),
            ItineraryDay(id: tokyoDay1, tripId: tripTokyoId, dayNumber: 1, date: dayOffset(0, from: tokyoStart)),
            ItineraryDay(id: tokyoDay2, tripId: tripTokyoId, dayNumber: 2, date: dayOffset(1, from: tokyoStart)),
            ItineraryDay(id: tokyoDay3, tripId: tripTokyoId, dayNumber: 3, date: dayOffset(2, from: tokyoStart)),
            ItineraryDay(id: tokyoDay4, tripId: tripTokyoId, dayNumber: 4, date: dayOffset(3, from: tokyoStart)),
            ItineraryDay(id: tokyoDay5, tripId: tripTokyoId, dayNumber: 5, date: dayOffset(4, from: tokyoStart)),
            ItineraryDay(id: tokyoDay6, tripId: tripTokyoId, dayNumber: 6, date: dayOffset(5, from: tokyoStart)),
            ItineraryDay(id: tokyoDay7, tripId: tripTokyoId, dayNumber: 7, date: dayOffset(6, from: tokyoStart)),
        ]

        dayPlacesMap[tokyoDay0] = [
            Place(id: UUID(uuidString: "32222222-2222-3333-4444-555555550001")!, itineraryDayId: tokyoDay0, name: "Tsukiji Outer Market", address: "4 Chome-16-2 Tsukiji, Chuo City, Tokyo", lat: 35.6654, lng: 139.7707, category: PlaceCategory.restaurant.rawValue, notes: nil, sortOrder: 0, startTime: nil, endTime: nil, isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "32222222-2222-3333-4444-555555550002")!, itineraryDayId: tokyoDay0, name: "teamLab Planets", address: "6-1-16 Toyosu, Koto City, Tokyo", lat: 35.6453, lng: 139.7991, category: PlaceCategory.attraction.rawValue, notes: nil, sortOrder: 1, startTime: nil, endTime: nil, isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
        ]

        let t1Date = dayOffset(0, from: tokyoStart)
        let tokyoFlightDep = time(on: t1Date, hour: 11, minute: 0)
        let tokyoFlightArr = time(on: t1Date, hour: 15, minute: 30)
        dayPlacesMap[tokyoDay1] = [
            Place(id: UUID(uuidString: "32222222-2222-3333-4444-555555550010")!, itineraryDayId: tokyoDay1, name: "UA 837 · SFO to NRT", address: "San Francisco International Airport", lat: 37.6213, lng: -122.3790, category: PlaceCategory.transport.rawValue, notes: nil, sortOrder: 0, startTime: tokyoFlightDep, endTime: tokyoFlightArr, isBooking: true, bookingType: BookingCategory.flight.rawValue, confirmationNumber: "UA837SFO", bookingDetails: .flight(FlightDetails(airline: "United Airlines", flightNumber: "837", departureAirport: "SFO", arrivalAirport: "NRT", departureTime: tokyoFlightDep, arrivalTime: tokyoFlightArr, terminal: "3", gate: "86", seat: "22A"))),
            Place(id: UUID(uuidString: "32222222-2222-3333-4444-555555550011")!, itineraryDayId: tokyoDay1, name: "Park Hyatt Tokyo", address: "3-7-1-2 Nishi-Shinjuku, Shinjuku City, Tokyo", lat: 35.6875, lng: 139.6920, category: PlaceCategory.hotel.rawValue, notes: nil, sortOrder: 1, startTime: nil, endTime: nil, isBooking: true, bookingType: BookingCategory.hotel.rawValue, confirmationNumber: "PHT-220011", bookingDetails: .hotel(HotelDetails(checkInDate: dayOffset(0, from: tokyoStart), checkInTime: "4:00 PM", checkOutDate: dayOffset(6, from: tokyoStart), checkOutTime: "11:00 AM", roomType: "Park King", nights: 6))),
        ]

        let t2Date = dayOffset(1, from: tokyoStart)
        dayPlacesMap[tokyoDay2] = [
            Place(id: UUID(uuidString: "32222222-2222-3333-4444-555555550020")!, itineraryDayId: tokyoDay2, name: "Shinjuku Gyoen", address: "11 Naitomachi, Shinjuku City, Tokyo", lat: 35.6852, lng: 139.7100, category: PlaceCategory.nature.rawValue, notes: nil, sortOrder: 0, startTime: time(on: t2Date, hour: 9, minute: 0), endTime: time(on: t2Date, hour: 11, minute: 0), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "32222222-2222-3333-4444-555555550021")!, itineraryDayId: tokyoDay2, name: "Takashimaya Times Square", address: "5-24-2 Sendagaya, Shibuya City, Tokyo", lat: 35.6893, lng: 139.7007, category: PlaceCategory.shopping.rawValue, notes: nil, sortOrder: 1, startTime: time(on: t2Date, hour: 12, minute: 0), endTime: time(on: t2Date, hour: 14, minute: 0), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "32222222-2222-3333-4444-555555550022")!, itineraryDayId: tokyoDay2, name: "Ichiran Ramen Shinjuku", address: "3-34-11 Shinjuku, Shinjuku City, Tokyo", lat: 35.6917, lng: 139.7000, category: PlaceCategory.restaurant.rawValue, notes: nil, sortOrder: 2, startTime: time(on: t2Date, hour: 19, minute: 0), endTime: time(on: t2Date, hour: 20, minute: 0), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "32222222-2222-3333-4444-555555550023")!, itineraryDayId: tokyoDay2, name: "Golden Gai", address: "1-1-6 Kabukicho, Shinjuku City, Tokyo", lat: 35.6948, lng: 139.7051, category: PlaceCategory.nightlife.rawValue, notes: nil, sortOrder: 3, startTime: time(on: t2Date, hour: 21, minute: 0), endTime: time(on: t2Date, hour: 23, minute: 0), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
        ]

        let t3Date = dayOffset(2, from: tokyoStart)
        dayPlacesMap[tokyoDay3] = [
            Place(id: UUID(uuidString: "32222222-2222-3333-4444-555555550030")!, itineraryDayId: tokyoDay3, name: "Meiji Shrine", address: "1-1 Yoyogikamizonocho, Shibuya City, Tokyo", lat: 35.6763, lng: 139.6993, category: PlaceCategory.attraction.rawValue, notes: nil, sortOrder: 0, startTime: time(on: t3Date, hour: 8, minute: 30), endTime: time(on: t3Date, hour: 10, minute: 0), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "32222222-2222-3333-4444-555555550031")!, itineraryDayId: tokyoDay3, name: "Takeshita Street Harajuku", address: "1-17-5 Jingumae, Shibuya City, Tokyo", lat: 35.6715, lng: 139.7044, category: PlaceCategory.shopping.rawValue, notes: nil, sortOrder: 1, startTime: time(on: t3Date, hour: 10, minute: 30), endTime: time(on: t3Date, hour: 12, minute: 0), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "32222222-2222-3333-4444-555555550032")!, itineraryDayId: tokyoDay3, name: "Shibuya Crossing", address: "2-2-1 Dogenzaka, Shibuya City, Tokyo", lat: 35.6595, lng: 139.7004, category: PlaceCategory.attraction.rawValue, notes: nil, sortOrder: 2, startTime: time(on: t3Date, hour: 14, minute: 0), endTime: time(on: t3Date, hour: 15, minute: 0), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "32222222-2222-3333-4444-555555550033")!, itineraryDayId: tokyoDay3, name: "Sushi Saito", address: "1-9-15 Akasaka, Minato City, Tokyo", lat: 35.6705, lng: 139.7380, category: PlaceCategory.restaurant.rawValue, notes: nil, sortOrder: 3, startTime: time(on: t3Date, hour: 19, minute: 30), endTime: time(on: t3Date, hour: 21, minute: 0), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
        ]

        let t4Date = dayOffset(3, from: tokyoStart)
        dayPlacesMap[tokyoDay4] = [
            Place(id: UUID(uuidString: "32222222-2222-3333-4444-555555550040")!, itineraryDayId: tokyoDay4, name: "Senso-ji Temple", address: "2-3-1 Asakusa, Taito City, Tokyo", lat: 35.7148, lng: 139.7967, category: PlaceCategory.attraction.rawValue, notes: nil, sortOrder: 0, startTime: time(on: t4Date, hour: 8, minute: 0), endTime: time(on: t4Date, hour: 10, minute: 0), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "32222222-2222-3333-4444-555555550041")!, itineraryDayId: tokyoDay4, name: "Nakamise Shopping Street", address: "Asakusa, Taito City, Tokyo", lat: 35.7126, lng: 139.7960, category: PlaceCategory.shopping.rawValue, notes: nil, sortOrder: 1, startTime: time(on: t4Date, hour: 10, minute: 15), endTime: time(on: t4Date, hour: 11, minute: 30), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "32222222-2222-3333-4444-555555550042")!, itineraryDayId: tokyoDay4, name: "Akihabara Electric Town", address: "Akihabara, Taito City, Tokyo", lat: 35.7022, lng: 139.7745, category: PlaceCategory.shopping.rawValue, notes: nil, sortOrder: 2, startTime: time(on: t4Date, hour: 14, minute: 0), endTime: time(on: t4Date, hour: 17, minute: 0), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
        ]

        let t5Date = dayOffset(4, from: tokyoStart)
        dayPlacesMap[tokyoDay5] = [
            Place(id: UUID(uuidString: "32222222-2222-3333-4444-555555550050")!, itineraryDayId: tokyoDay5, name: "teamLab Planets Tokyo", address: "6-1-16 Toyosu, Koto City, Tokyo", lat: 35.6453, lng: 139.7991, category: PlaceCategory.attraction.rawValue, notes: nil, sortOrder: 0, startTime: time(on: t5Date, hour: 10, minute: 0), endTime: time(on: t5Date, hour: 12, minute: 0), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "32222222-2222-3333-4444-555555550051")!, itineraryDayId: tokyoDay5, name: "Ginza Six", address: "6-10-1 Ginza, Chuo City, Tokyo", lat: 35.6698, lng: 139.7647, category: PlaceCategory.shopping.rawValue, notes: nil, sortOrder: 1, startTime: time(on: t5Date, hour: 14, minute: 0), endTime: time(on: t5Date, hour: 16, minute: 30), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "32222222-2222-3333-4444-555555550052")!, itineraryDayId: tokyoDay5, name: "Uobei Shibuya", address: "2-29-11 Dogenzaka, Shibuya City, Tokyo", lat: 35.6596, lng: 139.6983, category: PlaceCategory.restaurant.rawValue, notes: nil, sortOrder: 2, startTime: time(on: t5Date, hour: 19, minute: 0), endTime: time(on: t5Date, hour: 20, minute: 15), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
        ]

        let t6Date = dayOffset(5, from: tokyoStart)
        dayPlacesMap[tokyoDay6] = [
            Place(id: UUID(uuidString: "32222222-2222-3333-4444-555555550060")!, itineraryDayId: tokyoDay6, name: "Ueno Park", address: "Uenokoen, Taito City, Tokyo", lat: 35.7141, lng: 139.7741, category: PlaceCategory.nature.rawValue, notes: nil, sortOrder: 0, startTime: time(on: t6Date, hour: 9, minute: 0), endTime: time(on: t6Date, hour: 10, minute: 30), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "32222222-2222-3333-4444-555555550061")!, itineraryDayId: tokyoDay6, name: "Tokyo National Museum", address: "13-9 Uenokoen, Taito City, Tokyo", lat: 35.7188, lng: 139.7762, category: PlaceCategory.attraction.rawValue, notes: nil, sortOrder: 1, startTime: time(on: t6Date, hour: 10, minute: 45), endTime: time(on: t6Date, hour: 13, minute: 0), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "32222222-2222-3333-4444-555555550062")!, itineraryDayId: tokyoDay6, name: "Ameyoko Market", address: "4 Chome-7 Ueno, Taito City, Tokyo", lat: 35.7098, lng: 139.7735, category: PlaceCategory.shopping.rawValue, notes: nil, sortOrder: 2, startTime: time(on: t6Date, hour: 14, minute: 0), endTime: time(on: t6Date, hour: 16, minute: 0), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
        ]

        let t7Date = dayOffset(6, from: tokyoStart)
        let tokyoReturnDep = time(on: t7Date, hour: 10, minute: 30)
        let tokyoReturnArr = time(on: t7Date, hour: 7, minute: 0)
        dayPlacesMap[tokyoDay7] = [
            Place(id: UUID(uuidString: "32222222-2222-3333-4444-555555550070")!, itineraryDayId: tokyoDay7, name: "NH 10 · NRT to SFO", address: "Narita International Airport, Chiba", lat: 35.7720, lng: 140.3929, category: PlaceCategory.transport.rawValue, notes: nil, sortOrder: 0, startTime: tokyoReturnDep, endTime: tokyoReturnArr, isBooking: true, bookingType: BookingCategory.flight.rawValue, confirmationNumber: "NH10NRT", bookingDetails: .flight(FlightDetails(airline: "ANA", flightNumber: "10", departureAirport: "NRT", arrivalAirport: "SFO", departureTime: tokyoReturnDep, arrivalTime: tokyoReturnArr, terminal: "1", gate: "21", seat: "31D"))),
        ]

        // ── Barcelona ─────────────────────────────────────────────────────────

        let barcelonaDay0 = UUID(uuidString: "33333333-2222-3333-4444-555555550000")!
        let barcelonaDay1 = UUID(uuidString: "33333333-2222-3333-4444-555555550001")!
        let barcelonaDay2 = UUID(uuidString: "33333333-2222-3333-4444-555555550002")!
        let barcelonaDay3 = UUID(uuidString: "33333333-2222-3333-4444-555555550003")!
        let barcelonaDay4 = UUID(uuidString: "33333333-2222-3333-4444-555555550004")!
        let barcelonaDay5 = UUID(uuidString: "33333333-2222-3333-4444-555555550005")!

        tripDaysMap[tripBarcelonaId] = [
            ItineraryDay(id: barcelonaDay0, tripId: tripBarcelonaId, dayNumber: 0, date: barcelonaStart),
            ItineraryDay(id: barcelonaDay1, tripId: tripBarcelonaId, dayNumber: 1, date: dayOffset(0, from: barcelonaStart)),
            ItineraryDay(id: barcelonaDay2, tripId: tripBarcelonaId, dayNumber: 2, date: dayOffset(1, from: barcelonaStart)),
            ItineraryDay(id: barcelonaDay3, tripId: tripBarcelonaId, dayNumber: 3, date: dayOffset(2, from: barcelonaStart)),
            ItineraryDay(id: barcelonaDay4, tripId: tripBarcelonaId, dayNumber: 4, date: dayOffset(3, from: barcelonaStart)),
            ItineraryDay(id: barcelonaDay5, tripId: tripBarcelonaId, dayNumber: 5, date: dayOffset(4, from: barcelonaStart)),
        ]

        dayPlacesMap[barcelonaDay0] = [
            Place(id: UUID(uuidString: "33333333-2222-3333-4444-555555550001")!, itineraryDayId: barcelonaDay0, name: "Casa Batlló", address: "Passeig de Gràcia, 43, 08007 Barcelona", lat: 41.3916, lng: 2.1650, category: PlaceCategory.attraction.rawValue, notes: nil, sortOrder: 0, startTime: nil, endTime: nil, isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "33333333-2222-3333-4444-555555550002")!, itineraryDayId: barcelonaDay0, name: "El Bar Calders", address: "Carrer del Parlament, 25, 08015 Barcelona", lat: 41.3763, lng: 2.1622, category: PlaceCategory.nightlife.rawValue, notes: nil, sortOrder: 1, startTime: nil, endTime: nil, isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
        ]

        let b1Date = dayOffset(0, from: barcelonaStart)
        let bcnFlightDep = time(on: b1Date, hour: 7, minute: 30)
        let bcnFlightArr = time(on: b1Date, hour: 11, minute: 0)
        dayPlacesMap[barcelonaDay1] = [
            Place(id: UUID(uuidString: "33333333-2222-3333-4444-555555550010")!, itineraryDayId: barcelonaDay1, name: "IB 6275 · JFK to BCN", address: "John F. Kennedy International Airport", lat: 40.6413, lng: -73.7781, category: PlaceCategory.transport.rawValue, notes: nil, sortOrder: 0, startTime: bcnFlightDep, endTime: bcnFlightArr, isBooking: true, bookingType: BookingCategory.flight.rawValue, confirmationNumber: "IB6275JFK", bookingDetails: .flight(FlightDetails(airline: "Iberia", flightNumber: "6275", departureAirport: "JFK", arrivalAirport: "BCN", departureTime: bcnFlightDep, arrivalTime: bcnFlightArr, terminal: "7", gate: "B3", seat: "18F"))),
            Place(id: UUID(uuidString: "33333333-2222-3333-4444-555555550011")!, itineraryDayId: barcelonaDay1, name: "Hotel 1898", address: "La Rambla, 109, 08002 Barcelona", lat: 41.3820, lng: 2.1724, category: PlaceCategory.hotel.rawValue, notes: nil, sortOrder: 1, startTime: nil, endTime: nil, isBooking: true, bookingType: BookingCategory.hotel.rawValue, confirmationNumber: "H1898-5501", bookingDetails: .hotel(HotelDetails(checkInDate: dayOffset(0, from: barcelonaStart), checkInTime: "2:00 PM", checkOutDate: dayOffset(4, from: barcelonaStart), checkOutTime: "12:00 PM", roomType: "Superior Room", nights: 4))),
            Place(id: UUID(uuidString: "33333333-2222-3333-4444-555555550012")!, itineraryDayId: barcelonaDay1, name: "Barceloneta Beach", address: "Platja de la Barceloneta, 08003 Barcelona", lat: 41.3763, lng: 2.1921, category: PlaceCategory.nature.rawValue, notes: nil, sortOrder: 2, startTime: time(on: b1Date, hour: 15, minute: 0), endTime: time(on: b1Date, hour: 18, minute: 0), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "33333333-2222-3333-4444-555555550013")!, itineraryDayId: barcelonaDay1, name: "Can Solé", address: "Carrer de Sant Carles, 4, 08003 Barcelona", lat: 41.3771, lng: 2.1913, category: PlaceCategory.restaurant.rawValue, notes: nil, sortOrder: 3, startTime: time(on: b1Date, hour: 20, minute: 30), endTime: time(on: b1Date, hour: 22, minute: 0), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
        ]

        let b2Date = dayOffset(1, from: barcelonaStart)
        dayPlacesMap[barcelonaDay2] = [
            Place(id: UUID(uuidString: "33333333-2222-3333-4444-555555550020")!, itineraryDayId: barcelonaDay2, name: "Sagrada Família", address: "Carrer de Mallorca, 401, 08013 Barcelona", lat: 41.4036, lng: 2.1744, category: PlaceCategory.attraction.rawValue, notes: "Book tickets in advance!", sortOrder: 0, startTime: time(on: b2Date, hour: 9, minute: 0), endTime: time(on: b2Date, hour: 11, minute: 30), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "33333333-2222-3333-4444-555555550021")!, itineraryDayId: barcelonaDay2, name: "Casa Batlló", address: "Passeig de Gràcia, 43, 08007 Barcelona", lat: 41.3916, lng: 2.1650, category: PlaceCategory.attraction.rawValue, notes: nil, sortOrder: 1, startTime: time(on: b2Date, hour: 13, minute: 0), endTime: time(on: b2Date, hour: 14, minute: 30), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "33333333-2222-3333-4444-555555550022")!, itineraryDayId: barcelonaDay2, name: "La Pepita", address: "Carrer de Montserrat, 22, 08001 Barcelona", lat: 41.3857, lng: 2.1699, category: PlaceCategory.restaurant.rawValue, notes: nil, sortOrder: 2, startTime: time(on: b2Date, hour: 15, minute: 0), endTime: time(on: b2Date, hour: 16, minute: 30), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "33333333-2222-3333-4444-555555550023")!, itineraryDayId: barcelonaDay2, name: "Passeig de Gràcia stroll", address: "Passeig de Gràcia, 08007 Barcelona", lat: 41.3928, lng: 2.1660, category: PlaceCategory.nature.rawValue, notes: nil, sortOrder: 3, startTime: time(on: b2Date, hour: 17, minute: 0), endTime: time(on: b2Date, hour: 18, minute: 30), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
        ]

        let b3Date = dayOffset(2, from: barcelonaStart)
        dayPlacesMap[barcelonaDay3] = [
            Place(id: UUID(uuidString: "33333333-2222-3333-4444-555555550030")!, itineraryDayId: barcelonaDay3, name: "Park Güell", address: "08024 Barcelona", lat: 41.4145, lng: 2.1527, category: PlaceCategory.attraction.rawValue, notes: nil, sortOrder: 0, startTime: time(on: b3Date, hour: 8, minute: 30), endTime: time(on: b3Date, hour: 10, minute: 30), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "33333333-2222-3333-4444-555555550031")!, itineraryDayId: barcelonaDay3, name: "El Bar Calders", address: "Carrer del Parlament, 25, 08015 Barcelona", lat: 41.3763, lng: 2.1622, category: PlaceCategory.restaurant.rawValue, notes: nil, sortOrder: 1, startTime: time(on: b3Date, hour: 13, minute: 0), endTime: time(on: b3Date, hour: 14, minute: 30), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "33333333-2222-3333-4444-555555550032")!, itineraryDayId: barcelonaDay3, name: "Gràcia neighborhood", address: "Gràcia, 08012 Barcelona", lat: 41.4030, lng: 2.1569, category: PlaceCategory.attraction.rawValue, notes: nil, sortOrder: 2, startTime: time(on: b3Date, hour: 16, minute: 0), endTime: time(on: b3Date, hour: 18, minute: 0), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
        ]

        let b4Date = dayOffset(3, from: barcelonaStart)
        dayPlacesMap[barcelonaDay4] = [
            Place(id: UUID(uuidString: "33333333-2222-3333-4444-555555550040")!, itineraryDayId: barcelonaDay4, name: "Barcelona Gothic Quarter", address: "Barri Gòtic, 08002 Barcelona", lat: 41.3829, lng: 2.1774, category: PlaceCategory.attraction.rawValue, notes: nil, sortOrder: 0, startTime: time(on: b4Date, hour: 10, minute: 0), endTime: time(on: b4Date, hour: 12, minute: 0), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "33333333-2222-3333-4444-555555550041")!, itineraryDayId: barcelonaDay4, name: "Museu Picasso", address: "Carrer de Montcada, 15, 08003 Barcelona", lat: 41.3852, lng: 2.1808, category: PlaceCategory.attraction.rawValue, notes: nil, sortOrder: 1, startTime: time(on: b4Date, hour: 12, minute: 30), endTime: time(on: b4Date, hour: 14, minute: 30), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "33333333-2222-3333-4444-555555550042")!, itineraryDayId: barcelonaDay4, name: "El Xampanyet", address: "Carrer de Montcada, 22, 08003 Barcelona", lat: 41.3843, lng: 2.1812, category: PlaceCategory.nightlife.rawValue, notes: nil, sortOrder: 2, startTime: time(on: b4Date, hour: 19, minute: 30), endTime: time(on: b4Date, hour: 21, minute: 0), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
        ]

        let b5Date = dayOffset(4, from: barcelonaStart)
        let bcnReturnDep = time(on: b5Date, hour: 16, minute: 45)
        let bcnReturnArr = time(on: b5Date, hour: 19, minute: 30)
        dayPlacesMap[barcelonaDay5] = [
            Place(id: UUID(uuidString: "33333333-2222-3333-4444-555555550050")!, itineraryDayId: barcelonaDay5, name: "Montjuïc Castle", address: "Ctra de Montjuïc, 66, 08038 Barcelona", lat: 41.3638, lng: 2.1661, category: PlaceCategory.attraction.rawValue, notes: nil, sortOrder: 0, startTime: time(on: b5Date, hour: 10, minute: 0), endTime: time(on: b5Date, hour: 12, minute: 0), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "33333333-2222-3333-4444-555555550051")!, itineraryDayId: barcelonaDay5, name: "IB 6276 · BCN to JFK", address: "Aeropuerto de Barcelona–El Prat, El Prat de Llobregat", lat: 41.2971, lng: 2.0785, category: PlaceCategory.transport.rawValue, notes: nil, sortOrder: 1, startTime: bcnReturnDep, endTime: bcnReturnArr, isBooking: true, bookingType: BookingCategory.flight.rawValue, confirmationNumber: "IB6276BCN", bookingDetails: .flight(FlightDetails(airline: "Iberia", flightNumber: "6276", departureAirport: "BCN", arrivalAirport: "JFK", departureTime: bcnReturnDep, arrivalTime: bcnReturnArr, terminal: "1", gate: "A12", seat: "18F"))),
        ]

        let tripLondonId = UUID(uuidString: "11111111-2222-3333-4444-555555550004")!
        let londonStart = dayOffset(20)
        let londonEnd = endOfCalendarDay(dayOffset(25))
        let londonSync = tripServerSync(start: londonStart, end: londonEnd)
        let tripLondon = Trip(
            id: tripLondonId,
            userId: userId,
            title: "London Calling",
            destination: "London, UK",
            lat: 51.5074,
            lng: -0.1278,
            startDate: londonStart,
            endDate: londonEnd,
            coverImageUrl: "https://images.unsplash.com/photo-1513635269975-59663e0ac1ad?w=800&q=80",
            notes: nil,
            createdAt: dayOffset(-7),
            updatedAt: dayOffset(-3),
            databaseStatus: londonSync.status,
            isMarkedActiveOnServer: londonSync.isActive
        )
        // ── London ────────────────────────────────────────────────────────────

        let londonDay0 = UUID(uuidString: "44444444-2222-3333-4444-555555550000")!
        let londonDay1 = UUID(uuidString: "44444444-2222-3333-4444-555555550001")!
        let londonDay2 = UUID(uuidString: "44444444-2222-3333-4444-555555550002")!
        let londonDay3 = UUID(uuidString: "44444444-2222-3333-4444-555555550003")!
        let londonDay4 = UUID(uuidString: "44444444-2222-3333-4444-555555550004")!
        let londonDay5 = UUID(uuidString: "44444444-2222-3333-4444-555555550005")!

        tripDaysMap[tripLondonId] = [
            ItineraryDay(id: londonDay0, tripId: tripLondonId, dayNumber: 0, date: londonStart),
            ItineraryDay(id: londonDay1, tripId: tripLondonId, dayNumber: 1, date: dayOffset(0, from: londonStart)),
            ItineraryDay(id: londonDay2, tripId: tripLondonId, dayNumber: 2, date: dayOffset(1, from: londonStart)),
            ItineraryDay(id: londonDay3, tripId: tripLondonId, dayNumber: 3, date: dayOffset(2, from: londonStart)),
            ItineraryDay(id: londonDay4, tripId: tripLondonId, dayNumber: 4, date: dayOffset(3, from: londonStart)),
            ItineraryDay(id: londonDay5, tripId: tripLondonId, dayNumber: 5, date: dayOffset(4, from: londonStart)),
        ]

        dayPlacesMap[londonDay0] = [
            Place(id: UUID(uuidString: "44444444-2222-3333-4444-555555550001")!, itineraryDayId: londonDay0, name: "Borough Market", address: "8 Southwark St, London SE1 1TL", lat: 51.5055, lng: -0.0910, category: PlaceCategory.shopping.rawValue, notes: nil, sortOrder: 0, startTime: nil, endTime: nil, isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "44444444-2222-3333-4444-555555550002")!, itineraryDayId: londonDay0, name: "Shakespeare's Globe", address: "21 New Globe Walk, London SE1 9DT", lat: 51.5081, lng: -0.0972, category: PlaceCategory.attraction.rawValue, notes: nil, sortOrder: 1, startTime: nil, endTime: nil, isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
        ]

        let l1Date = dayOffset(0, from: londonStart)
        let lhrFlightDep = time(on: l1Date, hour: 9, minute: 15)
        let lhrFlightArr = time(on: l1Date, hour: 21, minute: 45)
        dayPlacesMap[londonDay1] = [
            Place(id: UUID(uuidString: "44444444-2222-3333-4444-555555550010")!, itineraryDayId: londonDay1, name: "BA 178 · JFK to LHR", address: "John F. Kennedy International Airport", lat: 40.6413, lng: -73.7781, category: PlaceCategory.transport.rawValue, notes: nil, sortOrder: 0, startTime: lhrFlightDep, endTime: lhrFlightArr, isBooking: true, bookingType: BookingCategory.flight.rawValue, confirmationNumber: "BA178JFK", bookingDetails: .flight(FlightDetails(airline: "British Airways", flightNumber: "178", departureAirport: "JFK", arrivalAirport: "LHR", departureTime: lhrFlightDep, arrivalTime: lhrFlightArr, terminal: "7", gate: "B32", seat: "25A"))),
            Place(id: UUID(uuidString: "44444444-2222-3333-4444-555555550011")!, itineraryDayId: londonDay1, name: "The Hoxton Southwark", address: "40 Blackfriars Rd, London SE1 8NY", lat: 51.5015, lng: -0.1020, category: PlaceCategory.hotel.rawValue, notes: nil, sortOrder: 1, startTime: nil, endTime: nil, isBooking: true, bookingType: BookingCategory.hotel.rawValue, confirmationNumber: "HOX-44120", bookingDetails: .hotel(HotelDetails(checkInDate: dayOffset(0, from: londonStart), checkInTime: "3:00 PM", checkOutDate: dayOffset(4, from: londonStart), checkOutTime: "12:00 PM", roomType: "Medium Room", nights: 4))),
        ]

        let l2Date = dayOffset(1, from: londonStart)
        dayPlacesMap[londonDay2] = [
            Place(id: UUID(uuidString: "44444444-2222-3333-4444-555555550020")!, itineraryDayId: londonDay2, name: "British Museum", address: "Great Russell St, London WC1B 3DG", lat: 51.5194, lng: -0.1270, category: PlaceCategory.attraction.rawValue, notes: nil, sortOrder: 0, startTime: time(on: l2Date, hour: 10, minute: 0), endTime: time(on: l2Date, hour: 13, minute: 0), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "44444444-2222-3333-4444-555555550021")!, itineraryDayId: londonDay2, name: "Covent Garden", address: "Covent Garden, London WC2E 8RF", lat: 51.5117, lng: -0.1240, category: PlaceCategory.shopping.rawValue, notes: nil, sortOrder: 1, startTime: time(on: l2Date, hour: 14, minute: 0), endTime: time(on: l2Date, hour: 16, minute: 0), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "44444444-2222-3333-4444-555555550022")!, itineraryDayId: londonDay2, name: "The Ivy Covent Garden", address: "1-5 West St, London WC2H 9NQ", lat: 51.5130, lng: -0.1262, category: PlaceCategory.restaurant.rawValue, notes: "Dinner reservation", sortOrder: 2, startTime: time(on: l2Date, hour: 19, minute: 0), endTime: time(on: l2Date, hour: 21, minute: 0), isBooking: true, bookingType: BookingCategory.restaurant.rawValue, confirmationNumber: "IVY-8812", bookingDetails: .restaurant(RestaurantDetails(reservationTime: time(on: l2Date, hour: 19, minute: 0), partySize: 2))),
        ]

        let l3Date = dayOffset(2, from: londonStart)
        dayPlacesMap[londonDay3] = [
            Place(id: UUID(uuidString: "44444444-2222-3333-4444-555555550030")!, itineraryDayId: londonDay3, name: "Buckingham Palace", address: "Buckingham Palace, London SW1A 1AA", lat: 51.5014, lng: -0.1419, category: PlaceCategory.attraction.rawValue, notes: nil, sortOrder: 0, startTime: time(on: l3Date, hour: 10, minute: 0), endTime: time(on: l3Date, hour: 11, minute: 30), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "44444444-2222-3333-4444-555555550031")!, itineraryDayId: londonDay3, name: "St James's Park", address: "St. James's Park, London SW1A 2BJ", lat: 51.5025, lng: -0.1340, category: PlaceCategory.nature.rawValue, notes: nil, sortOrder: 1, startTime: time(on: l3Date, hour: 11, minute: 45), endTime: time(on: l3Date, hour: 13, minute: 0), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "44444444-2222-3333-4444-555555550032")!, itineraryDayId: londonDay3, name: "Afternoon Tea at The Ritz", address: "150 Piccadilly, St. James's, London W1J 9BR", lat: 51.5071, lng: -0.1420, category: PlaceCategory.restaurant.rawValue, notes: "Dress code: smart attire", sortOrder: 2, startTime: time(on: l3Date, hour: 15, minute: 30), endTime: time(on: l3Date, hour: 17, minute: 30), isBooking: true, bookingType: BookingCategory.restaurant.rawValue, confirmationNumber: "RITZ-TEA991", bookingDetails: .restaurant(RestaurantDetails(reservationTime: time(on: l3Date, hour: 15, minute: 30), partySize: 2))),
        ]

        let l4Date = dayOffset(3, from: londonStart)
        dayPlacesMap[londonDay4] = [
            Place(id: UUID(uuidString: "44444444-2222-3333-4444-555555550040")!, itineraryDayId: londonDay4, name: "Tower of London", address: "St Katharine's & Wapping, London EC3N 4AB", lat: 51.5081, lng: -0.0759, category: PlaceCategory.attraction.rawValue, notes: nil, sortOrder: 0, startTime: time(on: l4Date, hour: 9, minute: 30), endTime: time(on: l4Date, hour: 12, minute: 0), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "44444444-2222-3333-4444-555555550041")!, itineraryDayId: londonDay4, name: "Tower Bridge", address: "Tower Bridge, London SE1 2UP", lat: 51.5055, lng: -0.0754, category: PlaceCategory.attraction.rawValue, notes: nil, sortOrder: 1, startTime: time(on: l4Date, hour: 12, minute: 15), endTime: time(on: l4Date, hour: 13, minute: 30), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "44444444-2222-3333-4444-555555550042")!, itineraryDayId: londonDay4, name: "Southbank Walk", address: "Southbank, London SE1", lat: 51.5072, lng: -0.1108, category: PlaceCategory.nature.rawValue, notes: nil, sortOrder: 2, startTime: time(on: l4Date, hour: 15, minute: 0), endTime: time(on: l4Date, hour: 17, minute: 0), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
        ]

        let l5Date = dayOffset(4, from: londonStart)
        let lhrReturnDep = time(on: l5Date, hour: 15, minute: 30)
        let lhrReturnArr = time(on: l5Date, hour: 18, minute: 15)
        dayPlacesMap[londonDay5] = [
            Place(id: UUID(uuidString: "44444444-2222-3333-4444-555555550050")!, itineraryDayId: londonDay5, name: "Camden Market", address: "Camden Lock Pl, London NW1 8AF", lat: 51.5441, lng: -0.1463, category: PlaceCategory.shopping.rawValue, notes: nil, sortOrder: 0, startTime: time(on: l5Date, hour: 10, minute: 0), endTime: time(on: l5Date, hour: 12, minute: 0), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "44444444-2222-3333-4444-555555550051")!, itineraryDayId: londonDay5, name: "BA 177 · LHR to JFK", address: "London Heathrow Airport, Longford TW6", lat: 51.4700, lng: -0.4543, category: PlaceCategory.transport.rawValue, notes: nil, sortOrder: 1, startTime: lhrReturnDep, endTime: lhrReturnArr, isBooking: true, bookingType: BookingCategory.flight.rawValue, confirmationNumber: "BA177LHR", bookingDetails: .flight(FlightDetails(airline: "British Airways", flightNumber: "177", departureAirport: "LHR", arrivalAirport: "JFK", departureTime: lhrReturnDep, arrivalTime: lhrReturnArr, terminal: "5", gate: "C52", seat: "25A"))),
        ]

        let tripRomeId = UUID(uuidString: "11111111-2222-3333-4444-555555550005")!
        let romeStart = dayOffset(-40)
        let romeEnd = endOfCalendarDay(dayOffset(-35))
        let romeSync = tripServerSync(start: romeStart, end: romeEnd)
        let tripRome = Trip(
            id: tripRomeId,
            userId: userId,
            title: "Ancient Rome",
            destination: "Rome, Italy",
            lat: 41.9028,
            lng: 12.4964,
            startDate: romeStart,
            endDate: romeEnd,
            coverImageUrl: "https://images.unsplash.com/photo-1552832230-c0197dd311b5?w=800&q=80",
            notes: nil,
            createdAt: dayOffset(-50),
            updatedAt: dayOffset(-45),
            databaseStatus: romeSync.status,
            isMarkedActiveOnServer: romeSync.isActive
        )
        // ── Rome ──────────────────────────────────────────────────────────────

        let romeDay0 = UUID(uuidString: "55555555-2222-3333-4444-555555550000")!
        let romeDay1 = UUID(uuidString: "55555555-2222-3333-4444-555555550001")!
        let romeDay2 = UUID(uuidString: "55555555-2222-3333-4444-555555550002")!
        let romeDay3 = UUID(uuidString: "55555555-2222-3333-4444-555555550003")!
        let romeDay4 = UUID(uuidString: "55555555-2222-3333-4444-555555550004")!
        let romeDay5 = UUID(uuidString: "55555555-2222-3333-4444-555555550005")!

        tripDaysMap[tripRomeId] = [
            ItineraryDay(id: romeDay0, tripId: tripRomeId, dayNumber: 0, date: romeStart),
            ItineraryDay(id: romeDay1, tripId: tripRomeId, dayNumber: 1, date: dayOffset(0, from: romeStart)),
            ItineraryDay(id: romeDay2, tripId: tripRomeId, dayNumber: 2, date: dayOffset(1, from: romeStart)),
            ItineraryDay(id: romeDay3, tripId: tripRomeId, dayNumber: 3, date: dayOffset(2, from: romeStart)),
            ItineraryDay(id: romeDay4, tripId: tripRomeId, dayNumber: 4, date: dayOffset(3, from: romeStart)),
            ItineraryDay(id: romeDay5, tripId: tripRomeId, dayNumber: 5, date: dayOffset(4, from: romeStart)),
        ]

        dayPlacesMap[romeDay0] = [
            Place(id: UUID(uuidString: "55555555-2222-3333-4444-555555550001")!, itineraryDayId: romeDay0, name: "Piazza Navona", address: "Piazza Navona, 00186 Roma RM", lat: 41.8992, lng: 12.4731, category: PlaceCategory.attraction.rawValue, notes: nil, sortOrder: 0, startTime: nil, endTime: nil, isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "55555555-2222-3333-4444-555555550002")!, itineraryDayId: romeDay0, name: "Castel Sant'Angelo", address: "Lungotevere Castello, 50, 00193 Roma RM", lat: 41.9031, lng: 12.4663, category: PlaceCategory.attraction.rawValue, notes: nil, sortOrder: 1, startTime: nil, endTime: nil, isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
        ]

        let r1Date = dayOffset(0, from: romeStart)
        let romeFltDep = time(on: r1Date, hour: 8, minute: 0)
        let romeFltArr = time(on: r1Date, hour: 12, minute: 30)
        dayPlacesMap[romeDay1] = [
            Place(id: UUID(uuidString: "55555555-2222-3333-4444-555555550010")!, itineraryDayId: romeDay1, name: "AZ 611 · JFK to FCO", address: "John F. Kennedy International Airport", lat: 40.6413, lng: -73.7781, category: PlaceCategory.transport.rawValue, notes: nil, sortOrder: 0, startTime: romeFltDep, endTime: romeFltArr, isBooking: true, bookingType: BookingCategory.flight.rawValue, confirmationNumber: "AZ611JFK", bookingDetails: .flight(FlightDetails(airline: "Alitalia", flightNumber: "611", departureAirport: "JFK", arrivalAirport: "FCO", departureTime: romeFltDep, arrivalTime: romeFltArr, terminal: "1", gate: "D22", seat: "20C"))),
            Place(id: UUID(uuidString: "55555555-2222-3333-4444-555555550011")!, itineraryDayId: romeDay1, name: "Hotel de Russie", address: "Via del Babuino, 9, 00187 Roma RM", lat: 41.9087, lng: 12.4773, category: PlaceCategory.hotel.rawValue, notes: nil, sortOrder: 1, startTime: nil, endTime: nil, isBooking: true, bookingType: BookingCategory.hotel.rawValue, confirmationNumber: "HDR-33009", bookingDetails: .hotel(HotelDetails(checkInDate: dayOffset(0, from: romeStart), checkInTime: "3:00 PM", checkOutDate: dayOffset(4, from: romeStart), checkOutTime: "12:00 PM", roomType: "Deluxe Room Garden View", nights: 4))),
            Place(id: UUID(uuidString: "55555555-2222-3333-4444-555555550012")!, itineraryDayId: romeDay1, name: "Trevi Fountain", address: "Piazza di Trevi, 00187 Roma RM", lat: 41.9009, lng: 12.4833, category: PlaceCategory.attraction.rawValue, notes: nil, sortOrder: 2, startTime: time(on: r1Date, hour: 16, minute: 0), endTime: time(on: r1Date, hour: 17, minute: 0), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "55555555-2222-3333-4444-555555550013")!, itineraryDayId: romeDay1, name: "Da Enzo al 29", address: "Via dei Vascellari, 29, 00153 Roma RM", lat: 41.8892, lng: 12.4719, category: PlaceCategory.restaurant.rawValue, notes: nil, sortOrder: 3, startTime: time(on: r1Date, hour: 20, minute: 0), endTime: time(on: r1Date, hour: 21, minute: 30), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
        ]

        let r2Date = dayOffset(1, from: romeStart)
        dayPlacesMap[romeDay2] = [
            Place(id: UUID(uuidString: "55555555-2222-3333-4444-555555550020")!, itineraryDayId: romeDay2, name: "Colosseum", address: "Piazza del Colosseo, 1, 00184 Roma RM", lat: 41.8902, lng: 12.4922, category: PlaceCategory.attraction.rawValue, notes: "Book timed entry tickets", sortOrder: 0, startTime: time(on: r2Date, hour: 9, minute: 0), endTime: time(on: r2Date, hour: 11, minute: 0), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "55555555-2222-3333-4444-555555550021")!, itineraryDayId: romeDay2, name: "Roman Forum", address: "Via Sacra, 00186 Roma RM", lat: 41.8925, lng: 12.4853, category: PlaceCategory.attraction.rawValue, notes: nil, sortOrder: 1, startTime: time(on: r2Date, hour: 11, minute: 30), endTime: time(on: r2Date, hour: 13, minute: 0), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "55555555-2222-3333-4444-555555550022")!, itineraryDayId: romeDay2, name: "Palatine Hill", address: "Via Sacra, 00186 Roma RM", lat: 41.8894, lng: 12.4877, category: PlaceCategory.attraction.rawValue, notes: nil, sortOrder: 2, startTime: time(on: r2Date, hour: 13, minute: 15), endTime: time(on: r2Date, hour: 14, minute: 30), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "55555555-2222-3333-4444-555555550023")!, itineraryDayId: romeDay2, name: "Il Sorpasso", address: "Via Properzio, 31-33, 00193 Roma RM", lat: 41.9042, lng: 12.4647, category: PlaceCategory.restaurant.rawValue, notes: nil, sortOrder: 3, startTime: time(on: r2Date, hour: 19, minute: 30), endTime: time(on: r2Date, hour: 21, minute: 0), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
        ]

        let r3Date = dayOffset(2, from: romeStart)
        dayPlacesMap[romeDay3] = [
            Place(id: UUID(uuidString: "55555555-2222-3333-4444-555555550030")!, itineraryDayId: romeDay3, name: "Vatican Museums", address: "Viale Vaticano, 00165 Roma RM", lat: 41.9065, lng: 12.4536, category: PlaceCategory.attraction.rawValue, notes: "Reserve online — queues are long", sortOrder: 0, startTime: time(on: r3Date, hour: 8, minute: 30), endTime: time(on: r3Date, hour: 12, minute: 0), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "55555555-2222-3333-4444-555555550031")!, itineraryDayId: romeDay3, name: "Sistine Chapel", address: "Piazza del Vaticano, 00120 Città del Vaticano", lat: 41.9029, lng: 12.4545, category: PlaceCategory.attraction.rawValue, notes: nil, sortOrder: 1, startTime: time(on: r3Date, hour: 12, minute: 0), endTime: time(on: r3Date, hour: 13, minute: 0), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "55555555-2222-3333-4444-555555550032")!, itineraryDayId: romeDay3, name: "St. Peter's Basilica", address: "Piazza San Pietro, 00120 Città del Vaticano", lat: 41.9022, lng: 12.4539, category: PlaceCategory.attraction.rawValue, notes: nil, sortOrder: 2, startTime: time(on: r3Date, hour: 14, minute: 0), endTime: time(on: r3Date, hour: 16, minute: 0), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
        ]

        let r4Date = dayOffset(3, from: romeStart)
        dayPlacesMap[romeDay4] = [
            Place(id: UUID(uuidString: "55555555-2222-3333-4444-555555550040")!, itineraryDayId: romeDay4, name: "Trastevere neighborhood", address: "Trastevere, 00153 Roma RM", lat: 41.8893, lng: 12.4701, category: PlaceCategory.attraction.rawValue, notes: nil, sortOrder: 0, startTime: time(on: r4Date, hour: 10, minute: 0), endTime: time(on: r4Date, hour: 12, minute: 0), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "55555555-2222-3333-4444-555555550041")!, itineraryDayId: romeDay4, name: "Villa Borghese Gardens", address: "Piazzale Napoleone I, 00197 Roma RM", lat: 41.9139, lng: 12.4896, category: PlaceCategory.nature.rawValue, notes: nil, sortOrder: 1, startTime: time(on: r4Date, hour: 14, minute: 0), endTime: time(on: r4Date, hour: 16, minute: 0), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "55555555-2222-3333-4444-555555550042")!, itineraryDayId: romeDay4, name: "Piazza del Popolo", address: "Piazza del Popolo, 00187 Roma RM", lat: 41.9107, lng: 12.4765, category: PlaceCategory.attraction.rawValue, notes: nil, sortOrder: 2, startTime: time(on: r4Date, hour: 16, minute: 30), endTime: time(on: r4Date, hour: 17, minute: 30), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "55555555-2222-3333-4444-555555550043")!, itineraryDayId: romeDay4, name: "Osteria der Belli", address: "Piazza S. Apollonia, 11, 00153 Roma RM", lat: 41.8902, lng: 12.4695, category: PlaceCategory.restaurant.rawValue, notes: nil, sortOrder: 3, startTime: time(on: r4Date, hour: 20, minute: 0), endTime: time(on: r4Date, hour: 21, minute: 30), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
        ]

        let r5Date = dayOffset(4, from: romeStart)
        let romeReturnDep = time(on: r5Date, hour: 14, minute: 0)
        let romeReturnArr = time(on: r5Date, hour: 17, minute: 45)
        dayPlacesMap[romeDay5] = [
            Place(id: UUID(uuidString: "55555555-2222-3333-4444-555555550050")!, itineraryDayId: romeDay5, name: "Piazza Navona morning", address: "Piazza Navona, 00186 Roma RM", lat: 41.8992, lng: 12.4731, category: PlaceCategory.attraction.rawValue, notes: nil, sortOrder: 0, startTime: time(on: r5Date, hour: 9, minute: 0), endTime: time(on: r5Date, hour: 10, minute: 30), isBooking: false, bookingType: nil, confirmationNumber: nil, bookingDetails: nil),
            Place(id: UUID(uuidString: "55555555-2222-3333-4444-555555550051")!, itineraryDayId: romeDay5, name: "AZ 612 · FCO to JFK", address: "Aeroporto di Roma-Fiumicino, 00054 Fiumicino RM", lat: 41.7999, lng: 12.2462, category: PlaceCategory.transport.rawValue, notes: nil, sortOrder: 1, startTime: romeReturnDep, endTime: romeReturnArr, isBooking: true, bookingType: BookingCategory.flight.rawValue, confirmationNumber: "AZ612FCO", bookingDetails: .flight(FlightDetails(airline: "Alitalia", flightNumber: "612", departureAirport: "FCO", arrivalAirport: "JFK", departureTime: romeReturnDep, arrivalTime: romeReturnArr, terminal: "3", gate: "G8", seat: "20C"))),
        ]

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


// =============================================================================

