import XCTest

/// Shared launch + navigation for booking E2E tests (`-wayfind-ui-testing` → `MockDataService`).
class BookingUITestBase: XCTestCase {
    var app: XCUIApplication!

    /// Seeded Tokyo day-1 bookings (see `MockDataService.buildSampleData`).
    enum SeededBookingRow {
        static let flight = "32222222-2222-3333-4444-555555550010"
        static let hotel = "32222222-2222-3333-4444-555555550011"
        static let restaurant = "32222222-2222-3333-4444-55555555e201"
        static let carRental = "32222222-2222-3333-4444-55555555e202"
        static let activity = "32222222-2222-3333-4444-55555555e203"
        static let transport = "32222222-2222-3333-4444-55555555e204"
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments.append("-wayfind-ui-testing")
        app.launch()
        signInAndOpenBookings()
    }

    /// Dismisses the iOS "Save Password?" overlay that the system renders inside
    /// the app window (iOS 17+). The popup appears asynchronously after sign-in
    /// so this must be called once the My Trips screen is visible.
    /// Uses a broad predicate so non-breaking spaces in the label don't matter.
    private func dismissSavePasswordSheetIfPresent() {
        let predicate = NSPredicate(
            format: "label CONTAINS[c] 'not now' OR label CONTAINS[c] 'don't save' OR label CONTAINS[c] 'never'"
        )
        let dismissBtn = app.descendants(matching: .any).matching(predicate).firstMatch
        if dismissBtn.waitForExistence(timeout: 6) {
            dismissBtn.tap()
        }
    }

    func signInAndOpenBookings() {
        XCTAssertTrue(
            app.textFields["Email"].waitForExistence(timeout: 25),
            "Sign-in email field should appear in UI-testing mock mode."
        )
        app.textFields["Email"].tap()
        app.textFields["Email"].typeText("e2e@wayfind.local")

        app.secureTextFields["Password"].tap()
        app.secureTextFields["Password"].typeText("not-used")

        app.buttons["Sign In"].tap()

        XCTAssertTrue(
            app.navigationBars["My Trips"].waitForExistence(timeout: 30),
            "Trips list should appear after mock sign-in."
        )

        // The "Save Password?" sheet appears on the My Trips screen after sign-in.
        dismissSavePasswordSheetIfPresent()

        let tripCard = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'Tokyo Adventure'")
        ).firstMatch
        XCTAssertTrue(tripCard.waitForExistence(timeout: 20), "Tokyo Adventure seed trip should be visible.")
        tripCard.tap()

        XCTAssertTrue(app.buttons["Bookings"].waitForExistence(timeout: 25), "Trip hub should expose Bookings.")
        app.buttons["Bookings"].tap()

        XCTAssertTrue(
            app.navigationBars["Bookings"].waitForExistence(timeout: 20),
            "Bookings sheet should present."
        )
    }

    func waitFor(_ element: XCUIElement, timeout: TimeInterval = 15) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Timed out waiting for \(element).")
    }

    func rowButton(id: String) -> XCUIElement {
        app.buttons["booking.row.\(id)"]
    }

    func primaryBookingAction() -> XCUIElement {
        app.buttons["addBooking.primaryAction"]
    }

    func tapAddBooking(category: String) {
        let add = app.buttons["bookings.add.\(category)"]
        waitFor(add)
        add.tap()
    }

    func dismissBookingEditorIfPresent() {
        let close = app.navigationBars.buttons["Close"]
        if close.waitForExistence(timeout: 2) {
            close.tap()
        }
    }

    /// Swipe-delete a row located by substring of its accessibility label (combined card label).
    func swipeDeleteRow(labelContaining substring: String) {
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] %@", substring)).firstMatch
        waitFor(row)
        row.swipeLeft()
        let delete = app.buttons["Delete"]
        waitFor(delete)
        delete.tap()
    }

    /// Booking list rows are `Button`s with a combined accessibility label (see `BookingPassCard`).
    func assertBookingRowVisible(containing substring: String, timeout: TimeInterval = 12) {
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] %@", substring)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: timeout), "Expected a booking row containing \(substring).")
    }

    func assertBookingRowNotVisible(containing substring: String, timeout: TimeInterval = 5) {
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] %@", substring)).firstMatch
        XCTAssertFalse(row.waitForExistence(timeout: timeout), "Expected no booking row containing \(substring).")
    }

    var airlinePickerButton: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Airline'")).firstMatch
    }
}
