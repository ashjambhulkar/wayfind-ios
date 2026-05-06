import XCTest

final class HotelBookingE2ETests: BookingUITestBase {
    func testAdd_primaryAction_disabledWithoutHotelName() {
        tapAddBooking(category: "hotel")
        waitFor(app.navigationBars["Add Hotel"])
        XCTAssertFalse(primaryBookingAction().isEnabled)
        app.navigationBars["Add Hotel"].buttons["Close"].tap()
    }

    func testAdd_happyPath_createsHotelRow() {
        let name = "UITest Hotel \(UUID().uuidString.prefix(5))"
        tapAddBooking(category: "hotel")
        let hotelField = app.textFields["e.g. Le Marais Hotel"]
        waitFor(hotelField)
        hotelField.tap()
        hotelField.typeText(name)
        XCTAssertTrue(primaryBookingAction().isEnabled)
        primaryBookingAction().tap()
        XCTAssertTrue(app.navigationBars["Bookings"].waitForExistence(timeout: 15))
        assertBookingRowVisible(containing: name)
    }

    func testEdit_changeConfirmation_persists() {
        let row = rowButton(id: SeededBookingRow.hotel)
        waitFor(row)
        row.tap()
        waitFor(app.navigationBars["Edit Hotel"])
        let conf = app.textFields["Confirmation (optional)"]
        waitFor(conf)
        conf.tap()
        conf.typeText("-uitest-hotel")
        primaryBookingAction().tap()
        XCTAssertTrue(app.navigationBars["Bookings"].waitForExistence(timeout: 15))
        rowButton(id: SeededBookingRow.hotel).tap()
        waitFor(conf)
        let value = conf.value as? String ?? ""
        XCTAssertTrue(value.contains("-uitest-hotel"))
        app.navigationBars["Edit Hotel"].buttons["Close"].tap()
    }

    func testDelete_removesNewlyAddedHotelRow() {
        let name = "UITest Hotel Del \(UUID().uuidString.prefix(5))"
        tapAddBooking(category: "hotel")
        let hotelField = app.textFields["e.g. Le Marais Hotel"]
        waitFor(hotelField)
        hotelField.tap()
        hotelField.typeText(name)
        primaryBookingAction().tap()
        XCTAssertTrue(app.navigationBars["Bookings"].waitForExistence(timeout: 15))
        assertBookingRowVisible(containing: name)
        swipeDeleteRow(labelContaining: name)
        assertBookingRowNotVisible(containing: name)
    }
}
