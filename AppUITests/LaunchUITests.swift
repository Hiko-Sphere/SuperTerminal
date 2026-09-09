import XCTest

/// Launch-level checks that run on a real device or simulator.
///
/// These are deliberately about *structure* rather than pixels: a screenshot test would
/// break on every design change, while "the empty state offers a way forward" is a claim
/// that should stay true.
@MainActor
final class LaunchUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testAppLaunchesAndOffersAConnection() throws {
        let app = XCUIApplication()
        app.launchEnvironment["ST_UITEST_RESET"] = "1"
        app.launch()

        XCTAssertTrue(
            app.navigationBars["Apex Terminal"].waitForExistence(timeout: 10),
            "the host list should be the first thing shown"
        )
        // The + button is a menu: there are two kinds of connection to add (D-027).
        XCTAssertTrue(
            app.buttons["add-connection"].exists,
            "an empty host list must offer a way to add one"
        )
        app.buttons["add-connection"].tap()
        XCTAssertTrue(app.buttons["add-ssh-connection"].waitForExistence(timeout: 5), "and the menu offers a connection")
        XCTAssertTrue(app.buttons["New Screen"].exists, "and a screen")
    }

    func testConnectionEditorValidatesBeforeSaving() throws {
        let app = XCUIApplication()
        app.launchEnvironment["ST_UITEST_RESET"] = "1"
        app.launch()

        app.buttons["add-connection"].tap()
        app.buttons["add-ssh-connection"].tap()
        XCTAssertTrue(app.navigationBars["New Connection"].waitForExistence(timeout: 5))
        // Save must stay disabled until the form is actually usable, rather than saving
        // a connection that cannot work.
        XCTAssertFalse(app.buttons["Save"].isEnabled)
    }
}
