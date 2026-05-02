import XCTest
@testable import wayfind

final class TimelinePlaceDisplayNameTests: XCTestCase {
    func testShortAllCapsPassesThroughGlobally() {
        XCTAssertEqual(TimelinePlaceDisplayName.timelineDisplay("NYC"), "NYC")
    }

    func testMixedCasePassesThroughUnchanged() {
        XCTAssertEqual(
            TimelinePlaceDisplayName.timelineDisplay("Café Luxembourg"),
            "Café Luxembourg"
        )
    }

    func testShoutingSentenceTitleCasesWordsLongerThanThreeLettersPreservesThreeLetterAbbrev() {
        XCTAssertEqual(
            TimelinePlaceDisplayName.timelineDisplay("BURJ KHALIFA — DUBAI OBSERVATION DECK NYC"),
            "Burj Khalifa — Dubai Observation Deck NYC"
        )
    }

    func testHyphenatedShoutingTokenizesAcrossHyphens() {
        XCTAssertEqual(
            TimelinePlaceDisplayName.timelineDisplay("FOO-BOROUGH PARK"),
            "FOO-Borough Park"
        )
    }

    func testFragmentsWithDigitsAreLeftUnchangedWithinShoutingStrings() {
        XCTAssertEqual(TimelinePlaceDisplayName.timelineDisplay("42ND STREET DINER MAIN"), "42ND Street Diner Main")
        XCTAssertEqual(TimelinePlaceDisplayName.timelineDisplay("SECTOR 9 FOOD PLAZA"), "Sector 9 Food Plaza")
    }
}
