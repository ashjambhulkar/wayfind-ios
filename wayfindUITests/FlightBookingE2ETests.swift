import XCTest

final class FlightBookingE2ETests: BookingUITestBase {
    func testAdd_primaryAction_disabledUntilMinimalFlightPath() {
        tapAddBooking(category: "flight")
        waitFor(app.navigationBars["Add Flight"])
        XCTAssertFalse(primaryBookingAction().isEnabled)
        app.navigationBars["Add Flight"].buttons["Close"].tap()
    }

    func testFlight_manualEntry_requiresAirportsBeforeSave() {
        tapAddBooking(category: "flight")
        waitFor(airlinePickerButton)
        airlinePickerButton.tap()
        XCTAssertTrue(app.navigationBars["Airline"].waitForExistence(timeout: 15))
        app.tables.cells.element(boundBy: 0).tap()

        let flightNo = app.textFields["e.g. 101"]
        waitFor(flightNo)
        flightNo.tap()
        flightNo.typeText("202")

        waitFor(app.buttons["Enter flight manually"])
        app.buttons["Enter flight manually"].tap()
        XCTAssertFalse(primaryBookingAction().isEnabled, "Save should stay off until both airports are set.")

        let fromField = app.textFields["Airport code, e.g. JFK"]
        waitFor(fromField)
        fromField.tap()
        fromField.typeText("JFK")

        let toField = app.textFields["Airport code, e.g. LAX"]
        waitFor(toField)
        toField.tap()
        toField.typeText("LAX")

        XCTAssertTrue(primaryBookingAction().isEnabled)
        app.navigationBars["Add Flight"].buttons["Close"].tap()
    }

    func testAdd_happyPath_createsFlightRow() {
        tapAddBooking(category: "flight")
        waitFor(airlinePickerButton)
        airlinePickerButton.tap()
        XCTAssertTrue(app.navigationBars["Airline"].waitForExistence(timeout: 15))
        app.tables.cells.element(boundBy: 0).tap()

        let flightNo = app.textFields["e.g. 101"]
        waitFor(flightNo)
        flightNo.tap()
        flightNo.typeText("777")

        waitFor(app.buttons["Enter flight manually"])
        app.buttons["Enter flight manually"].tap()

        app.textFields["Airport code, e.g. JFK"].tap()
        app.textFields["Airport code, e.g. JFK"].typeText("SFO")

        app.textFields["Airport code, e.g. LAX"].tap()
        app.textFields["Airport code, e.g. LAX"].typeText("NRT")

        XCTAssertTrue(primaryBookingAction().isEnabled)
        primaryBookingAction().tap()

        XCTAssertTrue(app.navigationBars["Bookings"].waitForExistence(timeout: 15))
        assertBookingRowVisible(containing: "777")
    }

    func testEdit_changeConfirmation_persists() {
        let row = rowButton(id: SeededBookingRow.flight)
        waitFor(row)
        row.tap()
        waitFor(app.navigationBars["Edit Flight"])

        let conf = app.textFields["Confirmation (optional)"]
        waitFor(conf)
        conf.tap()
        conf.typeText("-uitest")

        XCTAssertTrue(primaryBookingAction().isEnabled)
        primaryBookingAction().tap()

        XCTAssertTrue(app.navigationBars["Bookings"].waitForExistence(timeout: 15))
        rowButton(id: SeededBookingRow.flight).tap()
        waitFor(conf)
        let value = conf.value as? String ?? ""
        XCTAssertTrue(value.contains("-uitest"), "Edited confirmation should round-trip: \(value)")
        app.navigationBars["Edit Flight"].buttons["Close"].tap()
    }

    func testDelete_removesNewlyAddedFlightRow() {
        let marker = "UITestFlightDel-\(UUID().uuidString.prefix(6))"
        tapAddBooking(category: "flight")
        waitFor(airlinePickerButton)
        airlinePickerButton.tap()
        XCTAssertTrue(app.navigationBars["Airline"].waitForExistence(timeout: 15))
        app.tables.cells.element(boundBy: 0).tap()
        let flightNo = app.textFields["e.g. 101"]
        waitFor(flightNo)
        flightNo.tap()
        flightNo.typeText("888")
        waitFor(app.buttons["Enter flight manually"])
        app.buttons["Enter flight manually"].tap()
        app.textFields["Airport code, e.g. JFK"].tap()
        app.textFields["Airport code, e.g. JFK"].typeText("SEA")
        app.textFields["Airport code, e.g. LAX"].tap()
        app.textFields["Airport code, e.g. LAX"].typeText("PDX")

        let conf = app.textFields["Confirmation (optional)"]
        waitFor(conf)
        conf.tap()
        conf.typeText(marker)

        primaryBookingAction().tap()
        XCTAssertTrue(app.navigationBars["Bookings"].waitForExistence(timeout: 15))
        assertBookingRowVisible(containing: marker)

        swipeDeleteRow(labelContaining: marker)
        assertBookingRowNotVisible(containing: marker)
    }
}
