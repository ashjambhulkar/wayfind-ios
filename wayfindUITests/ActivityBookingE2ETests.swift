import XCTest

final class ActivityBookingE2ETests: BookingUITestBase {
    func testAdd_primaryAction_disabledWithoutActivityName() {
        tapAddBooking(category: "activity")
        waitFor(app.navigationBars["Add Activity"])
        XCTAssertFalse(primaryBookingAction().isEnabled)
        app.navigationBars["Add Activity"].buttons["Close"].tap()
    }

    func testAdd_happyPath_createsActivityRow() {
        let name = "UITest Activity \(UUID().uuidString.prefix(5))"
        tapAddBooking(category: "activity")
        let field = app.textFields["e.g. Seine River Cruise"]
        waitFor(field)
        field.tap()
        field.typeText(name)
        XCTAssertTrue(primaryBookingAction().isEnabled)
        primaryBookingAction().tap()
        XCTAssertTrue(app.navigationBars["Bookings"].waitForExistence(timeout: 15))
        assertBookingRowVisible(containing: name)
    }

    func testEdit_changeConfirmation_persists() {
        let row = rowButton(id: SeededBookingRow.activity)
        waitFor(row)
        row.tap()
        waitFor(app.navigationBars["Edit Activity"])
        let conf = app.textFields["Confirmation (optional)"]
        waitFor(conf)
        conf.tap()
        conf.typeText("-uitest-activity")
        primaryBookingAction().tap()
        XCTAssertTrue(app.navigationBars["Bookings"].waitForExistence(timeout: 15))
        rowButton(id: SeededBookingRow.activity).tap()
        waitFor(conf)
        let value = conf.value as? String ?? ""
        XCTAssertTrue(value.contains("-uitest-activity"))
        app.navigationBars["Edit Activity"].buttons["Close"].tap()
    }

    func testDelete_removesNewlyAddedActivityRow() {
        let name = "UITest Act Del \(UUID().uuidString.prefix(5))"
        tapAddBooking(category: "activity")
        let field = app.textFields["e.g. Seine River Cruise"]
        waitFor(field)
        field.tap()
        field.typeText(name)
        primaryBookingAction().tap()
        XCTAssertTrue(app.navigationBars["Bookings"].waitForExistence(timeout: 15))
        assertBookingRowVisible(containing: name)
        swipeDeleteRow(labelContaining: name)
        assertBookingRowNotVisible(containing: name)
    }
}
