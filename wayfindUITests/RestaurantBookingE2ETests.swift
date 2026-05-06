import XCTest

final class RestaurantBookingE2ETests: BookingUITestBase {
    func testAdd_primaryAction_disabledWithoutRestaurantName() {
        tapAddBooking(category: "restaurant")
        waitFor(app.navigationBars["Add Restaurant"])
        XCTAssertFalse(primaryBookingAction().isEnabled)
        app.navigationBars["Add Restaurant"].buttons["Close"].tap()
    }

    func testAdd_happyPath_createsRestaurantRow() {
        let name = "UITest Restaurant \(UUID().uuidString.prefix(5))"
        tapAddBooking(category: "restaurant")
        let field = app.textFields["e.g. Le Petit Cler"]
        waitFor(field)
        field.tap()
        field.typeText(name)
        XCTAssertTrue(primaryBookingAction().isEnabled)
        primaryBookingAction().tap()
        XCTAssertTrue(app.navigationBars["Bookings"].waitForExistence(timeout: 15))
        assertBookingRowVisible(containing: name)
    }

    func testEdit_changeConfirmation_persists() {
        let row = rowButton(id: SeededBookingRow.restaurant)
        waitFor(row)
        row.tap()
        waitFor(app.navigationBars["Edit Restaurant"])
        let conf = app.textFields["Confirmation (optional)"]
        waitFor(conf)
        conf.tap()
        conf.typeText("-uitest-restaurant")
        primaryBookingAction().tap()
        XCTAssertTrue(app.navigationBars["Bookings"].waitForExistence(timeout: 15))
        rowButton(id: SeededBookingRow.restaurant).tap()
        waitFor(conf)
        let value = conf.value as? String ?? ""
        XCTAssertTrue(value.contains("-uitest-restaurant"))
        app.navigationBars["Edit Restaurant"].buttons["Close"].tap()
    }

    func testDelete_removesNewlyAddedRestaurantRow() {
        let name = "UITest Rest Del \(UUID().uuidString.prefix(5))"
        tapAddBooking(category: "restaurant")
        let field = app.textFields["e.g. Le Petit Cler"]
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
