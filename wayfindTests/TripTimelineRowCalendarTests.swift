import XCTest
@testable import wayfind

final class TripTimelineRowCalendarTests: XCTestCase {
    func testSameCalendarDayUsesTimelineTimeZone() {
        let nyTZ = TimeZone(identifier: "America/New_York")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = nyTZ
        let anchorMay1 = cal.date(from: DateComponents(year: 2026, month: 5, day: 1))!
        let anchorMay2 = cal.date(from: DateComponents(year: 2026, month: 5, day: 2))!
        // Late evening May 1 in New York; stored instant is already May 2 in UTC.
        let utc = TimeZone(identifier: "UTC")!
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = utc
        let hotelDateStillMay1InNY = utcCal.date(from: DateComponents(year: 2026, month: 5, day: 2, hour: 3, minute: 30))!

        XCTAssertTrue(
            TripTimelineRowCalendar.isSameCalendarDay(
                hotelDate: hotelDateStillMay1InNY,
                itineraryAnchor: anchorMay1,
                timelineTimeZone: nyTZ
            )
        )

        XCTAssertFalse(
            TripTimelineRowCalendar.isSameCalendarDay(
                hotelDate: hotelDateStillMay1InNY,
                itineraryAnchor: anchorMay2,
                timelineTimeZone: nyTZ
            )
        )
    }
}
