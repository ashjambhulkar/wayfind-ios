import XCTest
@testable import wayfind

final class TimelineTravelSummaryFormattingTests: XCTestCase {
    func testTravelSummaryDoesNotUseMiddleDotBetweenDurationAndDistance() {
        let line = TimelineBetweenStopsPresentation.summaryLine(minutesText: "12 min", distanceText: "3 km")
        XCTAssertFalse(line.contains("·"))
        XCTAssertFalse(line.contains("•"))
        XCTAssertTrue(line.contains("12 min"))
        XCTAssertTrue(line.contains("3 km"))
    }
}
