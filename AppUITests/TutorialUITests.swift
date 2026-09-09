import XCTest

/// The tour (D-033): shown once on a fresh install, skippable, remembered, and reachable
/// again from Settings afterwards — which is the whole reason skipping is safe to offer.
@MainActor
final class TutorialUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func freshApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["ST_UITEST_RESET"] = "1"
        app.launchEnvironment["ST_UITEST_SHOW_TUTORIAL"] = "1"
        return app
    }

    func testTheTourIsShownOncePagesThroughAndIsRemembered() throws {
        let app = freshApp()
        app.launch()

        let tour = app.buttons["tutorial-skip"]
        XCTAssertTrue(tour.waitForExistence(timeout: 10), "a fresh install should be offered the tour")

        // Every page is reachable, and the last one ends it rather than continuing.
        let next = app.buttons["tutorial-next"]
        // Seven pages, so six taps of Continue reach the last one (D-056 added the one
        // about split panes). The count is deliberately literal rather than "tap until
        // Done appears": a tour that lost a page would still pass that, and the point of
        // this test is that every page is reachable.
        for step in 1 ... 6 {
            XCTAssertTrue(next.waitForExistence(timeout: 5), "step \(step) should offer Continue")
            next.tap()
        }
        let done = app.buttons["tutorial-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "the last page should finish rather than continue")
        XCTAssertFalse(next.exists, "and should not also offer Continue")

        // Going back is possible, and returns to Continue.
        app.buttons["tutorial-back"].tap()
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        next.tap()
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()

        XCTAssertTrue(app.buttons["add-connection"].waitForExistence(timeout: 10), "finishing reveals the app")
        XCTAssertFalse(tour.exists)

        // A relaunch without a reset must not show it again — this is the whole contract.
        let again = XCUIApplication()
        again.launchEnvironment["ST_UITEST_SHOW_TUTORIAL"] = "1"
        again.terminate()
        again.launch()
        XCTAssertTrue(again.buttons["add-connection"].waitForExistence(timeout: 10))
        XCTAssertFalse(again.buttons["tutorial-skip"].exists, "the tour is shown once, not every launch")
    }

    func testSkippingEndsItAndSettingsBringsItBack() throws {
        let app = freshApp()
        app.launch()

        let tour = app.buttons["tutorial-skip"]
        XCTAssertTrue(tour.waitForExistence(timeout: 10))
        app.buttons["tutorial-skip"].tap()
        XCTAssertTrue(app.buttons["add-connection"].waitForExistence(timeout: 10), "skipping should not gate anything")
        XCTAssertFalse(tour.exists)

        // Skipping counts as having seen it, so it does not reappear by itself…
        XCTAssertFalse(tour.waitForExistence(timeout: 2))

        // …and it is found again where someone looking for help would look.
        app.buttons["settings-open"].tap()
        let entry = app.buttons["settings-tutorial"]
        var attempts = 0
        while !entry.exists, attempts < 10 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "Settings should offer the tour again")
        entry.tap()
        XCTAssertTrue(tour.waitForExistence(timeout: 10), "and reopening it should work after a skip")

        // Skipping it a second time leaves Settings where it was, not the app behind it.
        app.buttons["tutorial-skip"].tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
    }
}
