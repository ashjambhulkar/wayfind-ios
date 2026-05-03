import XCTest
@testable import wayfind

final class TimelineTravelSpineDurationTests: XCTestCase {
    func testUnderTwentyFourHoursUsesHourMinuteTokens() {
        XCTAssertEqual(TimelineBetweenStopsPresentation.spineTravelDuration(minutes: 0), "0m")
        XCTAssertEqual(TimelineBetweenStopsPresentation.spineTravelDuration(minutes: 45), "45m")
        XCTAssertEqual(TimelineBetweenStopsPresentation.spineTravelDuration(minutes: 125), "2h 5m")
        XCTAssertEqual(TimelineBetweenStopsPresentation.spineTravelDuration(minutes: 120), "2h")
        XCTAssertEqual(TimelineBetweenStopsPresentation.spineTravelDuration(minutes: 1439), "23h 59m")
    }

    func testTwentyFourHoursAndUpUsesDayHourTokensAndOptionalMinutes() {
        XCTAssertEqual(TimelineBetweenStopsPresentation.spineTravelDuration(minutes: 1440), "1d")
        XCTAssertEqual(TimelineBetweenStopsPresentation.spineTravelDuration(minutes: 1485), "1d 45m")
        XCTAssertEqual(TimelineBetweenStopsPresentation.spineTravelDuration(minutes: 1565), "1d 2h 5m")
        XCTAssertEqual(TimelineBetweenStopsPresentation.spineTravelDuration(minutes: 2880), "2d")
        XCTAssertEqual(TimelineBetweenStopsPresentation.spineTravelDuration(minutes: 2900), "2d 20m")
    }

    func testNegativeMinutesClampToZero() {
        XCTAssertEqual(TimelineBetweenStopsPresentation.spineTravelDuration(minutes: -10), "0m")
    }
}
