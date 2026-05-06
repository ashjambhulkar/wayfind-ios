import XCTest

final class TransportBookingE2ETests: BookingUITestBase {
    func testAdd_primaryAction_disabledWithoutOperator() {
        tapAddBooking(category: "transport")
        waitFor(app.navigationBars["Add Transport"])
        XCTAssertFalse(primaryBookingAction().isEnabled)
        app.navigationBars["Add Transport"].buttons["Close"].tap()
    }

    func testTransport_saveDisabled_whenOperatorEmpty() {
        tapAddBooking(category: "transport")
        waitFor(app.navigationBars["Add Transport"])
        let service = app.textFields["e.g. 9014"]
        waitFor(service)
        service.tap()
        service.typeText("9999")
        XCTAssertFalse(primaryBookingAction().isEnabled, "Operator is required; Save must stay disabled.")
        app.navigationBars["Add Transport"].buttons["Close"].tap()
    }

    func testAdd_happyPath_createsTransportRow() {
        let op = "UITest Rail \(UUID().uuidString.prefix(5))"
        tapAddBooking(category: "transport")
        let operatorField = app.textFields["e.g. Eurostar"]
        waitFor(operatorField)
        operatorField.tap()
        operatorField.typeText(op)
        XCTAssertTrue(primaryBookingAction().isEnabled)
        primaryBookingAction().tap()
        XCTAssertTrue(app.navigationBars["Bookings"].waitForExistence(timeout: 15))
        assertBookingRowVisible(containing: op)
    }

    func testEdit_changeConfirmation_persists() {
        let row = rowButton(id: SeededBookingRow.transport)
        waitFor(row)
        row.tap()
        waitFor(app.navigationBars["Edit Transport"])
        let conf = app.textFields["Confirmation (optional)"]
        waitFor(conf)
        conf.tap()
        conf.typeText("-uitest-transport")
        primaryBookingAction().tap()
        XCTAssertTrue(app.navigationBars["Bookings"].waitForExistence(timeout: 15))
        rowButton(id: SeededBookingRow.transport).tap()
        waitFor(conf)
        let value = conf.value as? String ?? ""
        XCTAssertTrue(value.contains("-uitest-transport"))
        app.navigationBars["Edit Transport"].buttons["Close"].tap()
    }

    func testDelete_removesNewlyAddedTransportRow() {
        let op = "UITest Rail Del \(UUID().uuidString.prefix(5))"
        tapAddBooking(category: "transport")
        let operatorField = app.textFields["e.g. Eurostar"]
        waitFor(operatorField)
        operatorField.tap()
        operatorField.typeText(op)
        primaryBookingAction().tap()
        XCTAssertTrue(app.navigationBars["Bookings"].waitForExistence(timeout: 15))
        assertBookingRowVisible(containing: op)
        swipeDeleteRow(labelContaining: op)
        assertBookingRowNotVisible(containing: op)
    }
}
