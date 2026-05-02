import XCTest

/// Captures PNG screenshots for marketing / QA. Launch the app with
/// `-wayfind-ui-testing` so `AppConfig.useRealBackend` stays off (mock data).
///
/// Optional: set environment `SCREENSHOTS_DIR` to override the output directory.
/// If unset, PNGs go to `<repo>/screenshots/output` (derived from this source file’s location).
final class ScreenshotUITests: XCTestCase {
    private var app: XCUIApplication!

    private static var screenshotsOutputDirectory: URL {
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOTS_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("screenshots/output", isDirectory: true)
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments.append("-wayfind-ui-testing")
        app.launch()
    }

    func testCaptureScreens() throws {
        // Auth (mock backend — any credentials)
        XCTAssertTrue(
            app.textFields["Email"].waitForExistence(timeout: 20),
            "Sign-in email field should appear in UI-testing mock mode."
        )
        saveScreenshot(named: "01_sign_in")

        app.textFields["Email"].tap()
        app.textFields["Email"].typeText("screenshots@wayfind.local")

        app.secureTextFields["Password"].tap()
        app.secureTextFields["Password"].typeText("not-used")

        app.buttons["Sign In"].tap()

        let tripsNav = app.navigationBars["My Trips"]
        XCTAssertTrue(tripsNav.waitForExistence(timeout: 20))
        saveScreenshot(named: "02_trips_list")

        // Mock trips sort by latest startDate — Tokyo is first in the default seed.
        let tripTitle = app.staticTexts["Tokyo Adventure"]
        XCTAssertTrue(tripTitle.waitForExistence(timeout: 15))
        tripTitle.tap()

        XCTAssertTrue(app.buttons["Add Activity"].waitForExistence(timeout: 25))
        saveScreenshot(named: "03_trip_itinerary")

        app.buttons["Budget"].tap()
        let budgetBar = app.navigationBars["Budget"]
        XCTAssertTrue(budgetBar.waitForExistence(timeout: 15))
        saveScreenshot(named: "04_trip_budget_sheet")
        budgetBar.buttons["Close"].tap()

        app.buttons["Bookings"].tap()
        let bookingsBar = app.navigationBars["Bookings"]
        XCTAssertTrue(bookingsBar.waitForExistence(timeout: 15))
        saveScreenshot(named: "05_trip_bookings_sheet")
        bookingsBar.buttons["Close"].tap()

        app.buttons["More"].tap()
        app.buttons["Notes"].firstMatch.tap()
        let notesBar = app.navigationBars["Notes"]
        XCTAssertTrue(notesBar.waitForExistence(timeout: 15))
        saveScreenshot(named: "06_trip_notes")
        notesBar.buttons.element(boundBy: 0).tap()

        app.buttons["Trips"].tap()
        XCTAssertTrue(tripsNav.waitForExistence(timeout: 15))

        // Initials from mock sign-in: "Screenshots" → "SC"
        app.buttons["SC"].tap()
        XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: 15))
        saveScreenshot(named: "07_profile")
    }

    private func saveScreenshot(named name: String) {
        let shot = app.screenshot()

        let folder = Self.screenshotsOutputDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(name).png")
        try? shot.pngRepresentation.write(to: url)

        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
