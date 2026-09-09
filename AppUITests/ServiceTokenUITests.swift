import XCTest

/// A tunnelled connection can be given an Access service token instead of a browser
/// login, the token is required before saving, and reopening the connection shows the
/// token as stored without showing it.
@MainActor
final class ServiceTokenUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testServiceTokenIsRequiredSavedAndShownAsStored() throws {
        let app = XCUIApplication()
        app.launchEnvironment["ST_UITEST_RESET"] = "1"
        app.launch()

        app.buttons["add-connection"].tap()
        // The Cloudflare entry, which is how someone sets this up now (D-053): it opens
        // the same editor already switched to Cloudflare, so the toggle below is expected
        // to be on rather than needing a tap.
        app.buttons["add-cloudflare-connection"].tap()
        XCTAssertTrue(app.navigationBars["New Connection"].waitForExistence(timeout: 5))
        let name = "Token host"
        app.textFields["Name"].tap(); app.textFields["Name"].typeText(name)
        app.textFields["Hostname"].tap(); app.textFields["Hostname"].typeText("ssh.example.com")
        app.textFields["Username"].tap(); app.textFields["Username"].typeText("ops")
        // Already on, because the menu said which kind of connection this is. Asserting
        // rather than tapping makes this a check that the new entry really does what it
        // claims, instead of quietly tolerating it if it does not.
        let cloudflareSwitch = app.switches["Through Cloudflare Tunnel"].firstMatch
        XCTAssertTrue(cloudflareSwitch.waitForExistence(timeout: 5))
        XCTAssertEqual(cloudflareSwitch.value as? String, "1", "the Cloudflare entry should open the editor already set to it")

        let picker = app.descendants(matching: .any).matching(identifier: "access-auth-picker").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        app.buttons["Service token"].firstMatch.tap()

        // Choosing a service token without entering one must keep Save disabled.
        let idField = app.textFields["service-token-id"]
        XCTAssertTrue(idField.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Save"].isEnabled, "a service-token connection without a token cannot work")

        try idField.enter("abcdef.access", in: app)
        let secretField = app.secureTextFields["service-token-secret"]
        try secretField.enter("shh-not-a-real-secret", in: app)

        // The service token authenticates to Cloudflare; the host still needs an SSH
        // credential (further down the form — rows scrolled away stop existing, so the
        // token fields above are filled first), and the editor rightly refuses to save without one.
        try app.switches["Offer a password"].firstMatch.switchOn(in: app)
        XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Save"].isEnabled)
        app.buttons["Save"].tap()
        // iOS Password AutoFill must not offer to keep the secret in iCloud Keychain
        // passwords; it did until the secure fields opted out, and this is where it showed.
        XCTAssertFalse(app.sheets["Save Password?"].waitForExistence(timeout: 2), "no system password-save prompt")

        // Reopen: the token is reported as stored, and the secret is not displayed.
        // Swipe actions depend on gesture thresholds a test cannot see; the context menu
        // is the deterministic route to the editor. Wait for the editor sheet to be gone
        // first, or the press lands on it mid-animation.
        XCTAssertTrue(app.navigationBars["New Connection"].waitForNonExistence(timeout: 5))
        let row = app.buttons.matching(identifier: "host-row")
            .matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        for _ in 0 ..< 20 where !row.isHittable { usleep(150_000) }
        if !row.isHittable { add(XCTAttachment(string: app.debugDescription)) }
        XCTAssertTrue(row.isHittable, "the saved connection should be tappable once the editor is gone")
        row.press(forDuration: 1.0)
        let edit = app.buttons["Edit Connection"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "the row should offer Edit Connection in its context menu")
        edit.tap()
        XCTAssertTrue(app.navigationBars["Edit Connection"].waitForExistence(timeout: 5))
        let storedID = app.textFields["service-token-id"]
        XCTAssertTrue(storedID.waitForExistence(timeout: 5))
        XCTAssertTrue((storedID.placeholderValue ?? "").contains("stored"), "the editor should say a token is stored")
        XCTAssertEqual(storedID.value as? String ?? "", storedID.placeholderValue ?? "", "the stored client ID must not be shown")
        XCTAssertFalse(app.staticTexts["shh-not-a-real-secret"].exists)
        // Nothing typed, a token stored: still saveable.
        XCTAssertTrue(app.buttons["Save"].isEnabled)
    }
}

extension XCUIElement {
    /// Taps and types, making sure the field really took focus first: a field just below
    /// the keyboard raised by the previous one does not focus on tap, and `typeText` then
    /// fails with "neither element nor any descendant has keyboard focus".
    func enter(_ text: String, in app: XCUIApplication) throws {
        XCTAssertTrue(waitForExistence(timeout: 5), "the field should exist")
        for attempt in 0 ..< 4 {
            tap()
            usleep(300_000)
            if (value(forKey: "hasKeyboardFocus") as? Bool) == true { break }
            // Move the form so the field clears the keyboard, then try again.
            let form = app.collectionViews.firstMatch
            form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
                .press(forDuration: 0.05, thenDragTo: form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
            XCTAssertLessThan(attempt, 3, "\(identifier) never took keyboard focus")
        }
        typeText(text)
    }

    /// Taps the switch itself, not the row: XCUITest aims a plain `tap()` at the centre of
    /// the row's accessibility element, which activates nothing on this OS (see
    /// `SnippetUITests.turnOn`). Polls the value so a slow toggle animation cannot race
    /// the next step.
    func switchOn(in app: XCUIApplication) throws {
        // A form row scrolled out of view does not exist yet — on the iPad's form sheet the
        // password toggle sits below the fold once the token section expands — so scroll
        // the form until the row exists, then until it is hittable.
        let form = app.collectionViews.firstMatch
        var attempts = 0
        while !exists, attempts < 8 { form.swipeUp(); attempts += 1 }
        XCTAssertTrue(waitForExistence(timeout: 5), "the switch should exist")
        guard (value as? String) != "1" else { return }
        attempts = 0
        while !(exists && isHittable), attempts < 8 { form.swipeUp(); attempts += 1 }
        // Let the scroll settle: a tap dispatched mid-momentum lands wherever the row
        // has moved to by then.
        var frame = self.frame
        for _ in 0 ..< 20 {
            usleep(150_000)
            let current = self.frame
            if current == frame { break }
            frame = current
        }
        coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        for _ in 0 ..< 20 where (value as? String) != "1" { usleep(150_000) }
        XCTAssertEqual(value as? String, "1", "\(label) should be on after tapping the switch")
    }
}
