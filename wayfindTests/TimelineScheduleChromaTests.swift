import XCTest
@testable import wayfind

final class TimelineScheduleChromaTests: XCTestCase {
    private let newYork = TimeZone(identifier: "America/New_York")!

    func testNilScheduleIsFlexible() {
        XCTAssertEqual(
            TimelineScheduleChroma.tone(scheduleInstant: nil, timeZone: newYork),
            .flexible
        )
    }

    func testMorningAfternoonEveningNightBandsInTripTimeZone() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = newYork

        let morning = cal.date(from: DateComponents(year: 2026, month: 5, day: 1, hour: 5, minute: 0))!
        XCTAssertEqual(TimelineScheduleChroma.tone(scheduleInstant: morning, timeZone: newYork), .morning)

        let noonish = cal.date(from: DateComponents(year: 2026, month: 5, day: 1, hour: 14, minute: 30))!
        XCTAssertEqual(TimelineScheduleChroma.tone(scheduleInstant: noonish, timeZone: newYork), .afternoon)

        let evening = cal.date(from: DateComponents(year: 2026, month: 5, day: 1, hour: 19, minute: 0))!
        XCTAssertEqual(TimelineScheduleChroma.tone(scheduleInstant: evening, timeZone: newYork), .evening)

        let night = cal.date(from: DateComponents(year: 2026, month: 5, day: 1, hour: 21, minute: 0))!
        XCTAssertEqual(TimelineScheduleChroma.tone(scheduleInstant: night, timeZone: newYork), .night)

        let lateNight = cal.date(from: DateComponents(year: 2026, month: 5, day: 1, hour: 2, minute: 15))!
        XCTAssertEqual(TimelineScheduleChroma.tone(scheduleInstant: lateNight, timeZone: newYork), .night)
    }

    func testBandsUseDisplayedTimeZoneNotCurrentLocaleDefault() {
        let utc = TimeZone(identifier: "UTC")!
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = utc
        // 11:00 UTC → still morning bucket when user timeline is UTC.
        let instant = utcCal.date(from: DateComponents(year: 2026, month: 5, day: 1, hour: 11, minute: 0))!
        XCTAssertEqual(TimelineScheduleChroma.tone(scheduleInstant: instant, timeZone: utc), .morning)

        XCTAssertEqual(TimelineScheduleChroma.tone(scheduleInstant: instant, timeZone: newYork), .morning)
    }
}
