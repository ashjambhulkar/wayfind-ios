// PreviewMocks.swift — centralised static mock data for #Preview blocks.
// Compiled only in DEBUG so it never ships in release builds.

#if DEBUG
import CoreLocation
import Foundation
import SwiftUI

// MARK: - Stable mock IDs

enum MockID {
    static let user   = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEE0001")!
    static let user2  = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEE0002")!
    static let trip   = UUID(uuidString: "11111111-2222-3333-4444-555555550001")!
    static let day1   = UUID(uuidString: "21111111-2222-3333-4444-000000000001")!
    static let day2   = UUID(uuidString: "21111111-2222-3333-4444-000000000002")!
    static let place1 = UUID(uuidString: "31111111-2222-3333-4444-000000000001")!
    static let place2 = UUID(uuidString: "31111111-2222-3333-4444-000000000002")!
    static let place3 = UUID(uuidString: "31111111-2222-3333-4444-000000000003")!
}

// MARK: - Helpers

private func daysFromNow(_ n: Int) -> Date {
    Calendar.current.date(byAdding: .day, value: n, to: .now)!
}

private func mockTime(daysOffset: Int = 5, hour: Int, minute: Int = 0) -> Date {
    Calendar.current.date(
        bySettingHour: hour, minute: minute, second: 0,
        of: daysFromNow(daysOffset)
    )!
}

// MARK: - Trip

extension Trip {
    static let preview = Trip(
        id: MockID.trip,
        userId: MockID.user,
        title: "Paris Weekend",
        destination: "Paris, France",
        lat: 48.8566,
        lng: 2.3522,
        startDate: daysFromNow(5),
        endDate: daysFromNow(9),
        coverImageUrl: "https://images.unsplash.com/photo-1502602898657-3e91760cbb34?w=800&q=80",
        notes: nil,
        createdAt: .now,
        updatedAt: .now
    )

    static let previewActive = Trip(
        id: MockID.trip,
        userId: MockID.user,
        title: "Tokyo Adventure",
        destination: "Tokyo, Japan",
        lat: 35.6762,
        lng: 139.6503,
        startDate: daysFromNow(-1),
        endDate: daysFromNow(5),
        coverImageUrl: "https://images.unsplash.com/photo-1540959733332-eab4deabeeaf?w=800&q=80",
        notes: "Cherry blossom season!",
        createdAt: .now,
        updatedAt: .now
    )

    static let previewPast = Trip(
        id: MockID.trip,
        userId: MockID.user,
        title: "Barcelona Summer",
        destination: "Barcelona, Spain",
        lat: 41.3874,
        lng: 2.1686,
        startDate: daysFromNow(-20),
        endDate: daysFromNow(-14),
        coverImageUrl: "https://images.unsplash.com/photo-1583422409516-2895a77efded?w=800&q=80",
        notes: nil,
        createdAt: .now,
        updatedAt: .now
    )
}

// MARK: - ItineraryDay

extension ItineraryDay {
    static let preview1 = ItineraryDay(
        id: MockID.day1,
        tripId: MockID.trip,
        dayNumber: 1,
        date: daysFromNow(5)
    )

    static let preview2 = ItineraryDay(
        id: MockID.day2,
        tripId: MockID.trip,
        dayNumber: 2,
        date: daysFromNow(6)
    )

    static let previewWishlist = ItineraryDay(
        id: UUID(),
        tripId: MockID.trip,
        dayNumber: 0,
        date: nil
    )
}

// MARK: - Place

extension Place {
    /// Convenience factory for previews: only required fields are mandatory,
    /// everything else defaults to nil / sensible values.
    static func make(
        id: UUID = UUID(),
        itineraryDayId: UUID = MockID.day1,
        name: String,
        address: String? = nil,
        lat: Double? = nil,
        lng: Double? = nil,
        category: String? = nil,
        notes: String? = nil,
        sortOrder: Int = 0,
        startTime: Date? = nil,
        endTime: Date? = nil,
        isBooking: Bool = false,
        bookingType: String? = nil,
        confirmationNumber: String? = nil,
        bookingDetails: BookingDetailUnion? = nil,
        rating: Double? = nil,
        priceLevel: Int? = nil,
        heroImageUrl: String? = nil,
        aiShortSummary: String? = nil,
        durationMinutes: Int? = nil
    ) -> Place {
        Place(
            id: id,
            itineraryDayId: itineraryDayId,
            name: name,
            address: address,
            lat: lat,
            lng: lng,
            category: category,
            notes: notes,
            sortOrder: sortOrder,
            startTime: startTime,
            endTime: endTime,
            isBooking: isBooking,
            bookingType: bookingType,
            confirmationNumber: confirmationNumber,
            bookingDetails: bookingDetails,
            googlePlaceId: nil,
            bookingAmount: nil,
            bookingCurrencyCode: nil,
            heroImageUrl: heroImageUrl,
            rating: rating,
            userRatingsTotal: nil,
            priceLevel: priceLevel,
            website: nil,
            phoneNumber: nil,
            isOpenNow: nil,
            openingHoursText: nil,
            aiSummary: nil,
            aiShortSummary: aiShortSummary,
            whyGo: nil,
            knowBeforeYouGo: nil,
            reviewsTags: nil,
            durationMinutes: durationMinutes,
            subtypes: nil,
            travelFromPreviousMinutes: nil,
            travelMode: nil
        )
    }

    static let previewAttraction = Place.make(
        id: MockID.place1,
        itineraryDayId: MockID.day1,
        name: "Eiffel Tower",
        address: "Champ de Mars, 5 Av. Anatole France, 75007 Paris",
        lat: 48.8584,
        lng: 2.2945,
        category: "attraction",
        notes: "Book tickets in advance",
        sortOrder: 0,
        startTime: mockTime(hour: 9),
        endTime: mockTime(hour: 11),
        rating: 4.7,
        heroImageUrl: "https://images.unsplash.com/photo-1431274172761-fca41d930114?w=800&q=80",
        aiShortSummary: "Iconic iron lattice tower — symbol of Paris.",
        durationMinutes: 90
    )

    static let previewRestaurant = Place.make(
        id: MockID.place2,
        itineraryDayId: MockID.day1,
        name: "Le Jules Verne",
        address: "Eiffel Tower, 75007 Paris",
        lat: 48.8583,
        lng: 2.2944,
        category: "restaurant",
        sortOrder: 1,
        startTime: mockTime(hour: 12, minute: 30),
        endTime: mockTime(hour: 14),
        rating: 4.5,
        priceLevel: 4,
        aiShortSummary: "Michelin-starred restaurant inside the Eiffel Tower."
    )

    static let previewHotel = Place.make(
        id: MockID.place3,
        itineraryDayId: MockID.day1,
        name: "Hôtel Plaza Athénée",
        address: "25 Av. Montaigne, 75008 Paris",
        lat: 48.8673,
        lng: 2.3032,
        category: "hotel",
        sortOrder: 2,
        startTime: mockTime(hour: 15),
        isBooking: true,
        bookingType: "hotel",
        confirmationNumber: "HTL-2025-9876",
        bookingDetails: .hotel(HotelDetails(
            checkInDate: mockTime(hour: 15),
            checkInTime: "15:00",
            checkOutDate: Calendar.current.date(byAdding: .day, value: 4, to: mockTime(hour: 12)),
            checkOutTime: "12:00",
            roomType: "Deluxe Suite",
            nights: 4
        )),
        heroImageUrl: "https://images.unsplash.com/photo-1564501049412-61c2a3083791?w=800&q=80"
    )

    static let previewFlight = Place.make(
        itineraryDayId: MockID.day1,
        name: "CDG → NRT",
        address: "Charles de Gaulle Airport",
        lat: 49.0097,
        lng: 2.5479,
        category: "transport",
        sortOrder: 3,
        startTime: mockTime(hour: 7),
        endTime: mockTime(hour: 23),
        isBooking: true,
        bookingType: "flight",
        confirmationNumber: "AF264",
        bookingDetails: .flight(FlightDetails(
            airline: "Air France",
            carrierIATA: "AF",
            flightNumber: "AF264",
            departureAirport: "CDG",
            arrivalAirport: "NRT",
            departureTime: mockTime(hour: 7),
            arrivalTime: mockTime(hour: 23),
            terminal: "",
            gate: "",
            seat: "12A"
        ))
    )
}

// MARK: - TripCollaborator

extension TripCollaborator {
    static let previewOwner = TripCollaborator(
        id: nil,
        tripId: MockID.trip,
        userId: MockID.user,
        role: .owner,
        status: .accepted,
        invitedEmail: nil,
        displayName: "Alex Johnson",
        username: "@alexj",
        avatarURLString: nil,
        email: "alex@example.com"
    )

    static let previewEditor = TripCollaborator(
        id: UUID(),
        tripId: MockID.trip,
        userId: MockID.user2,
        role: .editor,
        status: .accepted,
        invitedEmail: nil,
        displayName: "Sam Rivera",
        username: "@samr",
        avatarURLString: nil,
        email: "sam@example.com"
    )

    static let previewPending = TripCollaborator(
        id: UUID(),
        tripId: MockID.trip,
        userId: nil,
        role: .viewer,
        status: .pending,
        invitedEmail: "friend@example.com",
        displayName: nil,
        username: nil,
        avatarURLString: nil,
        email: nil
    )
}

// MARK: - ParsedBooking

extension ParsedBooking {
    static let preview = ParsedBooking(
        id: UUID(),
        userId: MockID.user,
        tripId: MockID.trip,
        status: .parsed,
        parsedData: ["type": "flight", "confirmation": "ABC123", "airline": "British Airways"],
        createdAt: .now
    )
}

// MARK: - ActivityLogEntry

extension ActivityLogEntry {
    static let preview = ActivityLogEntry(
        id: UUID(),
        tripId: MockID.trip,
        userId: MockID.user,
        action: .activityAdded,
        entityType: "place",
        entityId: MockID.place1,
        entityName: "Eiffel Tower",
        metadata: nil,
        createdAt: .now
    )
}

// MARK: - InvitePreview

extension InvitePreview {
    static let preview = InvitePreview(
        tripId: MockID.trip,
        role: .editor,
        tripName: "Paris Weekend",
        coverImageURLString: "https://images.unsplash.com/photo-1502602898657-3e91760cbb34?w=800&q=80",
        startDate: daysFromNow(5),
        endDate: daysFromNow(9),
        destination: "Paris, France",
        inviterName: "Alex Johnson"
    )
}

// MARK: - MapSearchPreview

extension MapSearchPreview {
    static let preview = MapSearchPreview(
        id: "louvre-preview",
        origin: .cityPlaces,
        name: "Louvre Museum",
        subtitle: "Rue de Rivoli, 75001 Paris, France",
        coordinate: CLLocationCoordinate2D(latitude: 48.8606, longitude: 2.3376),
        category: .attraction
    )
}

// MARK: - TripBudget

extension TripBudget {
    static let preview = TripBudget(
        id: UUID(),
        tripId: MockID.trip,
        userId: MockID.user,
        category: .lodging,
        plannedAmount: Decimal(1500),
        currencyCode: "USD",
        createdAt: .now,
        updatedAt: .now
    )
}

// MARK: - TripExpense

extension TripExpense {
    static let preview = TripExpense(
        id: UUID(),
        tripId: MockID.trip,
        userId: MockID.user,
        payerUserId: MockID.user,
        bookingId: nil,
        title: "Hotel stay",
        amount: Decimal(320),
        currencyCode: "USD",
        category: .lodging,
        splitType: .equal,
        expenseDate: .now,
        notes: nil,
        isAutoSynced: false,
        createdAt: .now,
        updatedAt: .now
    )
}

// MARK: - TripNote

extension TripNote {
    static let preview = TripNote(
        id: UUID(),
        tripId: MockID.trip,
        userId: MockID.user,
        title: "Packing list",
        body: "- Passport\n- Adapter\n- Camera",
        createdAt: .now,
        updatedAt: .now
    )
}
#endif
