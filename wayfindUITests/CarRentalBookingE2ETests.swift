import XCTest

final class CarRentalBookingE2ETests: BookingUITestBase {
    func testAdd_primaryAction_disabledWithoutCompany() {
        tapAddBooking(category: "carRental")
        waitFor(app.navigationBars["Add Car Rental"])
        XCTAssertFalse(primaryBookingAction().isEnabled)
        app.navigationBars["Add Car Rental"].buttons["Close"].tap()
    }

    func testAdd_happyPath_createsCarRentalRow() {
        let company = "UITest Car \(UUID().uuidString.prefix(5))"
        tapAddBooking(category: "carRental")
        let field = app.textFields["e.g. Hertz"]
        waitFor(field)
        field.tap()
        field.typeText(company)
        XCTAssertTrue(primaryBookingAction().isEnabled)
        primaryBookingAction().tap()
        XCTAssertTrue(app.navigationBars["Bookings"].waitForExistence(timeout: 15))
        assertBookingRowVisible(containing: company)
    }

    func testEdit_changeConfirmation_persists() {
        let row = rowButton(id: SeededBookingRow.carRental)
        waitFor(row)
        row.tap()
        waitFor(app.navigationBars["Edit Car Rental"])
        let conf = app.textFields["Confirmation (optional)"]
        waitFor(conf)
        conf.tap()
        conf.typeText("-uitest-car")
        primaryBookingAction().tap()
        XCTAssertTrue(app.navigationBars["Bookings"].waitForExistence(timeout: 15))
        rowButton(id: SeededBookingRow.carRental).tap()
        waitFor(conf)
        let value = conf.value as? String ?? ""
        XCTAssertTrue(value.contains("-uitest-car"))
        app.navigationBars["Edit Car Rental"].buttons["Close"].tap()
    }

    func testDelete_removesNewlyAddedCarRentalRow() {
        let company = "UITest Car Del \(UUID().uuidString.prefix(5))"
        tapAddBooking(category: "carRental")
        let field = app.textFields["e.g. Hertz"]
        waitFor(field)
        field.tap()
        field.typeText(company)
        primaryBookingAction().tap()
        XCTAssertTrue(app.navigationBars["Bookings"].waitForExistence(timeout: 15))
        assertBookingRowVisible(containing: company)
        swipeDeleteRow(labelContaining: company)
        assertBookingRowNotVisible(containing: company)
    }
}
