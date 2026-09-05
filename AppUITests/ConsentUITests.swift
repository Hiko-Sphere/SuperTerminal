import XCTest

/// The consent screen: shown before anything else on a fresh install, readable, and
/// gone once accepted — including after a relaunch.
@MainActor
final class ConsentUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testConsentIsShownOnceAndRemembered() throws {
        let app = XCUIApplication()
        app.launchEnvironment["ST_UITEST_RESET"] = "1"
        app.launchEnvironment["ST_UITEST_SHOW_CONSENT"] = "1"
        app.launch()

        let accept = app.buttons["consent-accept"]
        XCTAssertTrue(accept.waitForExistence(timeout: 10), "the consent screen should gate a fresh install")

        // The documents are one tap away and actually render.
        app.buttons["consent-notice"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "SuperTerminal")).firstMatch.waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        XCTAssertTrue(accept.waitForExistence(timeout: 5))
        accept.tap()
        XCTAssertTrue(app.buttons["New Connection"].waitForExistence(timeout: 10), "accepting should reveal the app")
        XCTAssertFalse(accept.exists)

        // A relaunch without a reset must not ask again.
        app.terminate()
        let again = XCUIApplication()
        again.launch()
        XCTAssertTrue(again.buttons["New Connection"].waitForExistence(timeout: 10))
        XCTAssertFalse(again.buttons["consent-accept"].exists)
    }

    func testLegalDocumentsOpenFromSettings() throws {
        let app = XCUIApplication()
        app.launchEnvironment["ST_UITEST_RESET"] = "1"
        app.launch()
        app.buttons["Settings"].tap()
        let form = app.collectionViews["settings-form"].firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 10))
        let licences = app.buttons["settings-legal-licences"].firstMatch
        var attempts = 0
        while !licences.isHittable, attempts < 8 { form.swipeUp(); attempts += 1 }
        licences.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Apache")).firstMatch.waitForExistence(timeout: 10),
                      "the bundled notices should render")
    }
}
