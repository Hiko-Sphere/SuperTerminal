import XCTest

/// Launch-level checks that run on a real device or simulator.
///
/// These are deliberately about *structure* rather than pixels: a screenshot test would
/// break on every design change, while "the empty state offers a way forward" is a claim
/// that should stay true.
final class LaunchUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testAppLaunchesAndOffersAConnection() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(
            app.navigationBars["SuperTerminal"].waitForExistence(timeout: 10),
            "the host list should be the first thing shown"
        )
        XCTAssertTrue(
            app.buttons["New Connection"].exists,
            "an empty host list must offer a way to add one"
        )
    }

    func testConnectionEditorValidatesBeforeSaving() throws {
        let app = XCUIApplication()
        app.launch()

        app.buttons["New Connection"].tap()
        XCTAssertTrue(app.navigationBars["New Connection"].waitForExistence(timeout: 5))
        // Save must stay disabled until the form is actually usable, rather than saving
        // a connection that cannot work.
        XCTAssertFalse(app.buttons["Save"].isEnabled)
    }
}
