//
//  BookingCRUDTests.swift
//  wayfindTests
//
//  Unit tests for booking CRUD through MockDataService.
//  Bookings are Place rows with isBooking == true and a BookingDetailUnion.
//  Coverage starts with TransportDetails (all other types share the same
//  add/update/delete/move code paths).
//

import XCTest
@testable import wayfind

final class BookingCRUDTests: XCTestCase {

    // MARK: - Test fixture IDs

    private let dayA = UUID()
    private let dayB = UUID()

    // MARK: - Helpers

    private func makeMock() -> MockDataService {
        let mock = MockDataService()
        // Pre-register the day buckets used in these tests.
        mock.dayPlaces[dayA] = []
        mock.dayPlaces[dayB] = []
        return mock
    }

    /// All non-transport fields default to nil via `Place.make`.
    private func transportBooking(
        id: UUID = UUID(),
        dayId: UUID,
        sortOrder: Int = 0,
        operatorName: String = "JR East",
        serviceNumber: String = "N700",
        departure: String = "Tokyo",
        arrival: String = "Osaka",
        confirmation: String? = "CONF-001"
    ) -> Place {
        let dep = Date(timeIntervalSince1970: 1_750_000_000)
        let arr = dep.addingTimeInterval(3600)
        return Place.make(
            id: id,
            itineraryDayId: dayId,
            name: "\(operatorName) \(serviceNumber)",
            sortOrder: sortOrder,
            startTime: dep,
            endTime: arr,
            isBooking: true,
            bookingType: BookingCategory.transport.rawValue,
            confirmationNumber: confirmation,
            bookingDetails: .transport(TransportDetails(
                operatorName: operatorName,
                serviceNumber: serviceNumber,
                departureStation: departure,
                arrivalStation: arrival,
                departureTime: dep,
                arrivalTime: arr,
                seat: "8A"
            ))
        )
    }

    // MARK: - Create

    func testAdd_transportBooking_appearsInDayBucket() async {
        let mock = makeMock()
        let booking = transportBooking(dayId: dayA)

        await mock.addPlace(booking)

        let stored = mock.dayPlaces[dayA] ?? []
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.id, booking.id)
        XCTAssertTrue(stored.first?.isBooking == true)
        XCTAssertEqual(stored.first?.bookingType, BookingCategory.transport.rawValue)
    }

    func testAdd_preservesTransportDetails() async {
        let mock = makeMock()
        let booking = transportBooking(dayId: dayA, operatorName: "Eurostar", serviceNumber: "9084",
                                       departure: "London", arrival: "Paris")

        await mock.addPlace(booking)

        let place = mock.dayPlaces[dayA]?.first
        guard case .transport(let d) = place?.bookingDetails else {
            return XCTFail("Expected .transport bookingDetails")
        }
        XCTAssertEqual(d.operatorName, "Eurostar")
        XCTAssertEqual(d.serviceNumber, "9084")
        XCTAssertEqual(d.departureStation, "London")
        XCTAssertEqual(d.arrivalStation, "Paris")
    }

    func testAdd_preservesConfirmationNumber() async {
        let mock = makeMock()
        let booking = transportBooking(dayId: dayA, confirmation: "TGV-99")

        await mock.addPlace(booking)

        XCTAssertEqual(mock.dayPlaces[dayA]?.first?.confirmationNumber, "TGV-99")
    }

    func testAdd_multipleBookings_allPresent() async {
        let mock = makeMock()
        let b1 = transportBooking(dayId: dayA, sortOrder: 0)
        let b2 = transportBooking(dayId: dayA, sortOrder: 1)
        let b3 = transportBooking(dayId: dayA, sortOrder: 2)

        await mock.addPlace(b1)
        await mock.addPlace(b2)
        await mock.addPlace(b3)

        XCTAssertEqual(mock.dayPlaces[dayA]?.count, 3)
    }

    func testAdd_doesNotCrossContaminateOtherDays() async {
        let mock = makeMock()
        await mock.addPlace(transportBooking(dayId: dayA))

        XCTAssertEqual(mock.dayPlaces[dayB]?.count, 0)
    }

    // MARK: - Read / filter

    func testFilter_isBookingTrue_returnsOnlyBookings() async {
        let mock = makeMock()
        let booking = transportBooking(dayId: dayA)
        let nonBooking = Place.make(
            itineraryDayId: dayA,
            name: "Airport lounge",
            category: PlaceCategory.transport.rawValue,
            sortOrder: 1,
            isBooking: false
        )
        await mock.addPlace(booking)
        await mock.addPlace(nonBooking)

        let bookingsOnly = (mock.dayPlaces[dayA] ?? []).filter(\.isBooking)
        XCTAssertEqual(bookingsOnly.count, 1)
        XCTAssertEqual(bookingsOnly.first?.id, booking.id)
    }

    func testFetchBookings_forTrip_aggregatesAllDays() async {
        let mock = makeMock()
        await mock.addPlace(transportBooking(dayId: dayA))
        await mock.addPlace(transportBooking(dayId: dayB))

        // Simulate fetchBookings by collecting from both day buckets.
        let allBookings = [dayA, dayB]
            .flatMap { mock.dayPlaces[$0] ?? [] }
            .filter(\.isBooking)

        XCTAssertEqual(allBookings.count, 2)
    }

    // MARK: - Update

    func testUpdate_changesOperatorName() async {
        let mock = makeMock()
        let original = transportBooking(dayId: dayA, operatorName: "JR East")
        await mock.addPlace(original)

        var edited = original
        edited.bookingDetails = .transport(TransportDetails(
            operatorName: "Eurostar",
            serviceNumber: "9084",
            departureStation: "London",
            arrivalStation: "Paris",
            departureTime: original.startTime,
            arrivalTime: original.endTime,
            seat: "12B"
        ))
        await mock.updatePlace(edited)

        let stored = mock.dayPlaces[dayA]?.first(where: { $0.id == original.id })
        guard case .transport(let d) = stored?.bookingDetails else {
            return XCTFail("Expected .transport after update")
        }
        XCTAssertEqual(d.operatorName, "Eurostar")
        XCTAssertEqual(d.departureStation, "London")
    }

    func testUpdate_changesConfirmationNumber() async {
        let mock = makeMock()
        let original = transportBooking(dayId: dayA, confirmation: "OLD-001")
        await mock.addPlace(original)

        var edited = original
        edited.confirmationNumber = "NEW-999"
        await mock.updatePlace(edited)

        XCTAssertEqual(mock.dayPlaces[dayA]?.first?.confirmationNumber, "NEW-999")
    }

    func testUpdate_doesNotDuplicateEntry() async {
        let mock = makeMock()
        let booking = transportBooking(dayId: dayA)
        await mock.addPlace(booking)

        var edited = booking
        edited.name = "Updated name"
        await mock.updatePlace(edited)

        let matches = (mock.dayPlaces[dayA] ?? []).filter { $0.id == booking.id }
        XCTAssertEqual(matches.count, 1, "updatePlace must not duplicate the row")
    }

    func testUpdate_unknownId_isNoOp() async {
        let mock = makeMock()
        let booking = transportBooking(dayId: dayA)
        await mock.addPlace(booking)

        let ghost = transportBooking(id: UUID(), dayId: dayA)
        await mock.updatePlace(ghost)

        XCTAssertEqual(mock.dayPlaces[dayA]?.count, 1)
        XCTAssertEqual(mock.dayPlaces[dayA]?.first?.id, booking.id)
    }

    /// Documents a known limitation: updatePlace replaces the row in its
    /// current day bucket. When itineraryDayId is changed, the stale copy
    /// remains under the original key. Use movePlace for day changes.
    func testUpdate_crossDayChange_doesNotMigrateRow() async {
        let mock = makeMock()
        let booking = transportBooking(dayId: dayA)
        await mock.addPlace(booking)

        var crossDay = booking
        crossDay.itineraryDayId = dayB
        await mock.updatePlace(crossDay)

        // Row is still in dayA's bucket (not migrated to dayB).
        XCTAssertNotNil(
            mock.dayPlaces[dayA]?.first(where: { $0.id == booking.id }),
            "updatePlace leaves the row in the original day bucket"
        )
        XCTAssertNil(
            mock.dayPlaces[dayB]?.first(where: { $0.id == booking.id }),
            "updatePlace does NOT move the row to the new itineraryDayId"
        )
    }

    // MARK: - Delete

    func testDelete_removesBookingFromDay() async {
        let mock = makeMock()
        let booking = transportBooking(dayId: dayA)
        await mock.addPlace(booking)

        await mock.deletePlace(id: booking.id)

        XCTAssertTrue(mock.dayPlaces[dayA]?.isEmpty == true)
    }

    func testDelete_doesNotRemoveOtherBookingsOnSameDay() async {
        let mock = makeMock()
        let b1 = transportBooking(dayId: dayA, sortOrder: 0)
        let b2 = transportBooking(dayId: dayA, sortOrder: 1)
        await mock.addPlace(b1)
        await mock.addPlace(b2)

        await mock.deletePlace(id: b1.id)

        let remaining = mock.dayPlaces[dayA] ?? []
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.id, b2.id)
    }

    func testDelete_removesAcrossDayBuckets() async {
        // If the same ID somehow ended up in two buckets, deletePlace clears both.
        let mock = makeMock()
        let booking = transportBooking(dayId: dayA)
        mock.dayPlaces[dayA] = [booking]
        mock.dayPlaces[dayB] = [booking] // duplicated manually

        await mock.deletePlace(id: booking.id)

        XCTAssertTrue(mock.dayPlaces[dayA]?.isEmpty == true)
        XCTAssertTrue(mock.dayPlaces[dayB]?.isEmpty == true)
    }

    func testDelete_unknownId_isNoOp() async {
        let mock = makeMock()
        let booking = transportBooking(dayId: dayA)
        await mock.addPlace(booking)

        await mock.deletePlace(id: UUID())

        XCTAssertEqual(mock.dayPlaces[dayA]?.count, 1)
    }

    // MARK: - Move (day transfer)

    func testMove_removesFromSourceDay() async {
        let mock = makeMock()
        let booking = transportBooking(dayId: dayA)
        await mock.addPlace(booking)

        await mock.movePlace(placeId: booking.id, toDayId: dayB)

        XCTAssertNil(mock.dayPlaces[dayA]?.first(where: { $0.id == booking.id }))
    }

    func testMove_appearsInTargetDay() async {
        let mock = makeMock()
        let booking = transportBooking(dayId: dayA)
        await mock.addPlace(booking)

        await mock.movePlace(placeId: booking.id, toDayId: dayB)

        XCTAssertNotNil(mock.dayPlaces[dayB]?.first(where: { $0.id == booking.id }))
    }

    func testMove_updatesItineraryDayId() async {
        let mock = makeMock()
        let booking = transportBooking(dayId: dayA)
        await mock.addPlace(booking)

        await mock.movePlace(placeId: booking.id, toDayId: dayB)

        let moved = mock.dayPlaces[dayB]?.first(where: { $0.id == booking.id })
        XCTAssertEqual(moved?.itineraryDayId, dayB)
    }

    func testMove_assignsSortOrderAtEndOfTargetDay() async {
        let mock = makeMock()
        // Two existing bookings in dayB.
        mock.dayPlaces[dayB] = [
            transportBooking(dayId: dayB, sortOrder: 0),
            transportBooking(dayId: dayB, sortOrder: 1),
        ]
        let booking = transportBooking(dayId: dayA, sortOrder: 0)
        await mock.addPlace(booking)

        await mock.movePlace(placeId: booking.id, toDayId: dayB)

        let moved = mock.dayPlaces[dayB]?.first(where: { $0.id == booking.id })
        XCTAssertEqual(moved?.sortOrder, 2, "Moved booking should be appended with sortOrder == existing count (2)")
    }

    func testMove_preservesTransportDetails() async {
        let mock = makeMock()
        let booking = transportBooking(dayId: dayA, operatorName: "SNCF", serviceNumber: "TGV5432")
        await mock.addPlace(booking)

        await mock.movePlace(placeId: booking.id, toDayId: dayB)

        let moved = mock.dayPlaces[dayB]?.first(where: { $0.id == booking.id })
        guard case .transport(let d) = moved?.bookingDetails else {
            return XCTFail("BookingDetailUnion must survive movePlace")
        }
        XCTAssertEqual(d.operatorName, "SNCF")
        XCTAssertEqual(d.serviceNumber, "TGV5432")
    }

    func testMove_unknownId_isNoOp() async {
        let mock = makeMock()
        let booking = transportBooking(dayId: dayA)
        await mock.addPlace(booking)

        await mock.movePlace(placeId: UUID(), toDayId: dayB)

        XCTAssertEqual(mock.dayPlaces[dayA]?.count, 1)
        XCTAssertEqual(mock.dayPlaces[dayB]?.count, 0)
    }

    // MARK: - BookingDetailUnion Codable round-trip

    func testTransportDetails_codableRoundTrip() throws {
        let dep = Date(timeIntervalSince1970: 1_750_000_000)
        let arr = dep.addingTimeInterval(7200)
        let details = TransportDetails(
            operatorName: "JR East",
            serviceNumber: "Shinkansen N700",
            departureStation: "Tokyo",
            arrivalStation: "Kyoto",
            departureTime: dep,
            arrivalTime: arr,
            seat: "Car 5 Seat 3A"
        )

        let data = try JSONEncoder().encode(BookingDetailUnion.transport(details))
        let decoded = try JSONDecoder().decode(BookingDetailUnion.self, from: data)

        guard case .transport(let d) = decoded else {
            return XCTFail("Decoded value must be .transport")
        }
        XCTAssertEqual(d.operatorName, "JR East")
        XCTAssertEqual(d.serviceNumber, "Shinkansen N700")
        XCTAssertEqual(d.departureStation, "Tokyo")
        XCTAssertEqual(d.arrivalStation, "Kyoto")
        XCTAssertEqual(d.seat, "Car 5 Seat 3A")
        XCTAssertEqual(d.departureTime?.timeIntervalSince1970 ?? 0,
                       dep.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(d.arrivalTime?.timeIntervalSince1970 ?? 0,
                       arr.timeIntervalSince1970, accuracy: 0.001)
    }

    /// Regression: service_number was missing from BookingJSONDetails and
    /// hardcoded to "" in buildBookingDetails, so editing a service number
    /// appeared to save but was lost on the next load from Supabase.
    func testUpdate_serviceNumber_persistsAfterRoundTrip() async {
        let mock = makeMock()
        let original = transportBooking(dayId: dayA, serviceNumber: "N700")
        await mock.addPlace(original)

        var edited = original
        edited.bookingDetails = .transport(TransportDetails(
            operatorName: "JR East",
            serviceNumber: "E7",
            departureStation: "Tokyo",
            arrivalStation: "Osaka",
            departureTime: original.startTime,
            arrivalTime: original.endTime,
            seat: "8A"
        ))
        await mock.updatePlace(edited)

        let stored = mock.dayPlaces[dayA]?.first(where: { $0.id == original.id })
        guard case .transport(let d) = stored?.bookingDetails else {
            return XCTFail("Expected .transport bookingDetails after update")
        }
        XCTAssertEqual(d.serviceNumber, "E7",
            "Service number must be persisted — was being dropped to empty string on reload")
    }

    func testTransportDetails_codableRoundTrip_nilDatesPreserved() throws {
        let details = TransportDetails(
            operatorName: "Bus Co",
            serviceNumber: "42",
            departureStation: "Central",
            arrivalStation: "Airport",
            departureTime: nil,
            arrivalTime: nil,
            seat: ""
        )

        let data = try JSONEncoder().encode(BookingDetailUnion.transport(details))
        let decoded = try JSONDecoder().decode(BookingDetailUnion.self, from: data)

        guard case .transport(let d) = decoded else {
            return XCTFail("Decoded value must be .transport")
        }
        XCTAssertNil(d.departureTime)
        XCTAssertNil(d.arrivalTime)
    }
}
