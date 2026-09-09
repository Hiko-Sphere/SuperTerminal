import XCTest

/// The app lock end to end (D-023): set a passcode in Settings, relaunch, and the lock
/// screen stands in front of everything until the right passcode is entered; leaving
/// and returning locks again. Face ID is the system's and a device check.
@MainActor
final class AppLockUITests: XCTestCase {
    private lazy var app = XCUIApplication()

    // An override may *add* actor isolation when it is async, because the caller awaits
    // the hop; `setUpWithError()` cannot, and every line below touches `XCUIApplication`,
    // which is the main actor's (D-068).
    @MainActor
    override func setUp() async throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        for key in ["ST_UITEST_SEED", "ST_UITEST_HOST", "ST_UITEST_PORT", "ST_UITEST_USER",
                    "ST_UITEST_KEY", "ST_UITEST_TRUST_HOST_KEYS", "ST_UITEST_NAME"] {
            if let value = environment[key] { app.launchEnvironment[key] = value }
        }
        try XCTSkipUnless(environment["ST_UITEST_SEED"] == "1", "needs the seeded state so the run starts clean")
        app.launch()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Scrolls Settings until the row is there to be used.
    ///
    /// A long `Form` keeps only the rows near the viewport in the accessibility tree, so a
    /// row below the fold does not exist until it is scrolled to — and a control that exists
    /// but is off-screen cannot be tapped at a coordinate either. Settings has grown a
    /// section every few changes; scrolling for what a test needs is what stops the next
    /// section from breaking this one.
    @discardableResult
    private func settingsRow(_ identifier: String) -> XCUIElement {
        let row = element(identifier)
        var attempts = 0
        while (!row.exists || !row.isHittable), attempts < 20 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Settings should offer \(identifier)")
        return row
    }

    func testPasscodeLocksTheAppAcrossALaunchAndAfterLeaving() throws {
        // Settings → App lock → set a passcode.
        app.buttons["Settings"].tap()
        // Scroll first: on a phone *and* on an iPad the App lock switch is now below the
        // fold, and a row below the fold is not in the accessibility tree at all.
        settingsRow("applock-enabled")
        let toggle = app.switches["applock-enabled"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "Settings should carry the App lock switch")
        // The switch control, not the row: a plain tap lands on the row's centre, which
        // flips nothing (see `switchOn(in:)`). The value cannot be polled here — it stays
        // off until a passcode is saved — so the sheet is the evidence.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let newField = app.secureTextFields["applock-new"]
        XCTAssertTrue(newField.waitForExistence(timeout: 5), "turning the lock on asks for a passcode")
        newField.tap()
        newField.typeText("open sesame")
        let confirm = app.secureTextFields["applock-confirm"]
        confirm.tap()
        confirm.typeText("open sesam")
        app.buttons["applock-save"].tap()
        XCTAssertTrue(element("applock-problem").waitForExistence(timeout: 5), "a mismatch is said, not silently accepted")
        confirm.tap()
        confirm.typeText("open sesame")
        app.buttons["applock-save"].tap()
        XCTAssertTrue(settingsRow("applock-change").exists, "with the lock on, Settings offers to change the passcode")
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertFalse(element("lock-screen").exists, "turning the lock on does not lock the screen the user is on")

        // Relaunch, keeping the state: the lock stands in front of everything.
        app.terminate()
        app.launchEnvironment["ST_UITEST_KEEP_STATE"] = "1"
        app.launch()
        let lockScreen = element("lock-screen")
        XCTAssertTrue(lockScreen.waitForExistence(timeout: 10), "the app opens locked")
        XCTAssertFalse(app.buttons["Settings"].isHittable, "nothing behind the lock is reachable")
        let passcode = app.secureTextFields["lock-passcode"]
        XCTAssertTrue(passcode.waitForExistence(timeout: 5))
        passcode.tap()
        passcode.typeText("wrong\n")
        XCTAssertTrue(element("lock-error").waitForExistence(timeout: 5), "a wrong passcode is said")
        XCTAssertTrue(lockScreen.exists)
        passcode.tap()
        passcode.typeText("open sesame\n")
        XCTAssertTrue(lockScreen.waitForNonExistence(timeout: 10), "the right passcode opens the app")
        XCTAssertTrue(app.buttons["Settings"].isHittable, "and what was behind the lock is reachable again")

        // Leaving and coming back locks again (the default is "immediately").
        #if targetEnvironment(macCatalyst)
        // A Mac has no home button, and `XCUIDevice.press` does not exist there. Deactivating
        // by activating something else is the closest equivalent, and it is what a person
        // does: click away, come back (D-070).
        XCUIApplication(bundleIdentifier: "com.apple.finder").activate()
        #else
        XCUIDevice.shared.press(.home)
        #endif
        app.activate()
        XCTAssertTrue(lockScreen.waitForExistence(timeout: 10), "coming back after leaving locks the app")
        passcode.tap()
        passcode.typeText("open sesame\n")
        XCTAssertTrue(lockScreen.waitForNonExistence(timeout: 10))
    }
}
