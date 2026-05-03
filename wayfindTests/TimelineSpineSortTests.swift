import XCTest
@testable import wayfind

final class TimelineSpineSortTests: XCTestCase {
    private var dayAnchorsMay1May2: (checkIn: Date, checkOut: Date) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let checkIn = cal.date(from: DateComponents(year: 2026, month: 5, day: 1, hour: 15, minute: 0))!
        let checkOut = cal.date(from: DateComponents(year: 2026, month: 5, day: 2, hour: 11, minute: 0))!
        return (checkIn, checkOut)
    }

    func testRestaurantUsesReservationWhenStartTimeNil() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let reservation = cal.date(from: DateComponents(year: 2026, month: 5, day: 1, hour: 16, minute: 6))!

        let place = Place.make(
            name: "Dinner",
            startTime: nil,
            isBooking: true,
            bookingType: BookingCategory.restaurant.rawValue,
            bookingDetails: .restaurant(RestaurantDetails(reservationTime: reservation, partySize: 2))
        )

        XCTAssertEqual(place.timelineSpineSortInstant(hotelTimelineRole: nil), reservation)
    }

    func testRestaurantReservationOrdersBeforeLaterFlightWithoutStartTimes() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!

        let dinner = Place.make(
            name: "Dinner booking",
            sortOrder: 0,
            startTime: nil,
            isBooking: true,
            bookingType: BookingCategory.restaurant.rawValue,
            bookingDetails: .restaurant(
                RestaurantDetails(
                    reservationTime: cal.date(from: DateComponents(year: 2026, month: 5, day: 1, hour: 16, minute: 6))!,
                    partySize: 2
                )
            )
        )

        let flight = Place.make(
            name: "Red-eye",
            sortOrder: 1,
            startTime: nil,
            isBooking: true,
            bookingType: BookingCategory.flight.rawValue,
            bookingDetails: .flight(
                FlightDetails(
                    airline: "Test",
                    flightNumber: "99",
                    departureAirport: "SFO",
                    arrivalAirport: "JFK",
                    departureTime: cal.date(from: DateComponents(year: 2026, month: 5, day: 1, hour: 21, minute: 12))!,
                    arrivalTime: cal.date(from: DateComponents(year: 2026, month: 5, day: 2, hour: 5, minute: 30))!,
                    terminal: "1",
                    gate: "B2",
                    seat: "12A"
                )
            )
        )

        let a = dinner.timelineSpineSortInstant(hotelTimelineRole: nil)!
        let b = flight.timelineSpineSortInstant(hotelTimelineRole: nil)!
        XCTAssertLessThan(a, b)
    }

    func testHotelCheckOutInstantAfterCheckInWhenStartTimeUnset() {
        let (checkIn, checkOut) = dayAnchorsMay1May2
        let hotel = Place.make(
            name: "Grand Hotel",
            startTime: nil,
            isBooking: true,
            bookingType: BookingCategory.hotel.rawValue,
            bookingDetails: .hotel(
                HotelDetails(
                    checkInDate: checkIn,
                    checkInTime: "3:00 PM",
                    checkOutDate: checkOut,
                    checkOutTime: "11:00 AM",
                    roomType: "King",
                    nights: 1
                )
            )
        )

        let inKey = hotel.timelineSpineSortInstant(hotelTimelineRole: .checkIn)!
        let outKey = hotel.timelineSpineSortInstant(hotelTimelineRole: .checkOut)!
        XCTAssertLessThan(inKey, outKey)
    }

    func testTimelineClockSortIgnoresStoredDateComponent() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!

        let morning = Place.make(
            name: "Morning stop",
            startTime: cal.date(from: DateComponents(year: 2026, month: 5, day: 2, hour: 9, minute: 0))
        )
        let evening = Place.make(
            name: "Evening stop",
            startTime: cal.date(from: DateComponents(year: 2026, month: 5, day: 1, hour: 17, minute: 0))
        )

        let morningRow = TripTimelineDisplayRow(id: "morning", place: morning, hotelTimelineRole: nil)
        let eveningRow = TripTimelineDisplayRow(id: "evening", place: evening, hotelTimelineRole: nil)

        XCTAssertLessThan(
            morningRow.timelineSortClockSeconds(timeZone: cal.timeZone)!,
            eveningRow.timelineSortClockSeconds(timeZone: cal.timeZone)!
        )
    }
}
