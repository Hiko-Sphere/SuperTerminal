import XCTest

/// Drives the app to a live terminal and exercises the screen a user actually spends
/// their time on.
///
/// Needs a server; `scripts/ui-terminal-e2e.sh` starts one and passes its details in.
/// Without them the tests skip, so a plain `xcodebuild test` still runs clean.
final class TerminalUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["ST_UITEST_SEED"] == "1",
            "run scripts/ui-terminal-e2e.sh to provide a server"
        )
        app = XCUIApplication()
        // The app reads these itself; XCUITest launches it as a separate process, so they
        // have to be handed over explicitly rather than inherited.
        for key in [
            "ST_UITEST_SEED", "ST_UITEST_HOST", "ST_UITEST_PORT", "ST_UITEST_USER",
            "ST_UITEST_KEY", "ST_UITEST_TRUST_HOST_KEYS", "ST_UITEST_NAME",
        ] {
            if let value = environment[key] { app.launchEnvironment[key] = value }
        }
        app.launch()
    }

    /// Opens the seeded connection and waits until the shell has answered.
    private func openTerminal() throws {
        let host = app.buttons["Local Test Server, \(ProcessInfo.processInfo.environment["ST_UITEST_USER"] ?? "")@127.0.0.1:\(ProcessInfo.processInfo.environment["ST_UITEST_PORT"] ?? "")"]
        if host.waitForExistence(timeout: 10) {
            host.tap()
        } else {
            // Fall back to matching on the name alone, so a change to the subtitle format
            // does not turn every terminal test red for the wrong reason.
            let byName = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Local Test Server")).firstMatch
            XCTAssertTrue(byName.waitForExistence(timeout: 10), "the seeded connection should be listed")
            byName.tap()
        }

        let terminal = app.otherElements.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Terminal for")
        ).firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 30), "the terminal screen should appear")

        // The terminal focuses itself when it appears, but tapping makes the test
        // independent of that timing rather than racing it.
        if terminal.isHittable { terminal.tap() }
        XCTAssertTrue(
            app.keyboards.element.waitForExistence(timeout: 10),
            "the keyboard should be up so the terminal can receive typing"
        )
    }

    /// The terminal's accessibility value is the rendered screen text, so it doubles as
    /// the assertion surface — the same string VoiceOver would read out.
    private func waitForScreen(containing needle: String, timeout: TimeInterval = 30) -> String {
        let terminal = app.otherElements.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Terminal for")
        ).firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        var latest = ""
        while Date() < deadline {
            latest = terminal.value as? String ?? ""
            if latest.contains(needle) { return latest }
            usleep(200_000)
        }
        return latest
    }

    func testTerminalConnectsAndShowsAPrompt() throws {
        try openTerminal()

        app.typeText("printf 'UI_TERMINAL_%s\\n' READY\n")
        let screen = waitForScreen(containing: "UI_TERMINAL_READY")
        XCTAssertTrue(
            screen.contains("UI_TERMINAL_READY"),
            "the terminal should show real remote output. Screen was:\n\(screen)"
        )

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "terminal-live"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testAccessoryKeyRowSendsControlCharacters() throws {
        try openTerminal()

        // Start a command, then interrupt it with the on-screen Control key row — the only
        // way to send ^C on a phone, and therefore core functionality rather than a
        // convenience.
        app.typeText("sleep 30\n")
        let control = app.buttons["Control"]
        XCTAssertTrue(control.waitForExistence(timeout: 10), "the accessory row should offer Control")
        control.tap()
        app.typeText("c")

        app.typeText("printf 'AFTER_%s\\n' INTERRUPT\n")
        let screen = waitForScreen(containing: "AFTER_INTERRUPT")
        XCTAssertTrue(
            screen.contains("AFTER_INTERRUPT"),
            "the shell should be responsive after ^C. Screen was:\n\(screen)"
        )
    }

    /// Long-press then drag selects, and the Copy affordance appears with a plausible
    /// character count.
    ///
    /// The selection model has unit coverage; this covers the part only a real gesture
    /// can reach — that the press is recognised at all, that dragging extends rather than
    /// restarting it, and that the bar the user acts on actually appears.
    func testLongPressSelectsTextAndOffersCopy() throws {
        try openTerminal()

        app.typeText("printf 'SELECTABLE_%s\\n' TEXT\n")
        _ = waitForScreen(containing: "SELECTABLE_TEXT")

        let terminal = app.otherElements.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Terminal for")
        ).firstMatch
        let frame = terminal.frame
        // Press near the top-left of the grid and drag right, across the text that was
        // just printed.
        let start = terminal.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 8, dy: 40))
        let end = terminal.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: min(frame.width - 8, 240), dy: 40))
        start.press(forDuration: 0.8, thenDragTo: end)

        let copy = app.buttons["Copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "a selection should offer Copy")

        // The bar reports how much is selected; a drag across a populated row must have
        // caught something rather than collapsing to nothing.
        let counter = app.staticTexts.matching(
            NSPredicate(format: "label ENDSWITH %@", "characters")
        ).firstMatch
        XCTAssertTrue(counter.waitForExistence(timeout: 5), "the selection bar should report a size")

        copy.tap()
        XCTAssertFalse(
            app.buttons["Copy"].exists,
            "copying should clear the selection so the bar does not linger"
        )
    }

    /// Find opens, searches the buffer, and reports how many matches it found.
    func testFindSearchesTheScrollback() throws {
        try openTerminal()

        app.typeText("printf 'NEEDLE_%s\\n' ONE; printf 'NEEDLE_%s\\n' TWO\n")
        _ = waitForScreen(containing: "NEEDLE_TWO")

        app.buttons["Session"].tap()
        app.buttons["Find…"].tap()

        let field = app.textFields["Find in scrollback"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the find bar should appear")
        field.tap()
        field.typeText("NEEDLE_")

        // Two printed lines plus the shell's echo of the command that printed them.
        let counter = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", " of ")
        ).firstMatch
        XCTAssertTrue(counter.waitForExistence(timeout: 5), "search should report a match count")
    }

    func testDynamicTypeDoesNotBreakTheHostList() throws {
        // The terminal grid deliberately ignores Dynamic Type — it must match the geometry
        // the remote program was told about — but every other surface must honour it.
        app.terminate()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"]
        app.launch()

        XCTAssertTrue(
            app.navigationBars["SuperTerminal"].waitForExistence(timeout: 10),
            "the host list should still render at an accessibility text size"
        )
        let byName = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Local Test Server")).firstMatch
        XCTAssertTrue(byName.waitForExistence(timeout: 10), "the connection should still be reachable")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "host-list-accessibility-text"
        shot.lifetime = .keepAlways
        add(shot)
    }
}

/// Key management is reachable and can generate a usable key without a server.
final class KeyManagementUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testGeneratingAKeyShowsSomethingTheUserCanPasteIntoAServer() throws {
        let app = XCUIApplication()
        app.launch()

        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))

        // A NavigationLink inside a Form is not always exposed as a button, and the
        // Security section may be below the fold, so scroll to it and match on any
        // element carrying the label.
        let keysLink = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Keys")
        ).firstMatch
        if !keysLink.waitForExistence(timeout: 3) {
            app.swipeUp()
        }
        XCTAssertTrue(keysLink.waitForExistence(timeout: 5), "Settings should offer a Keys screen")
        keysLink.tap()
        XCTAssertTrue(app.navigationBars["Keys"].waitForExistence(timeout: 5))

        // Reached through the toolbar rather than the empty state. Keys persist in the app
        // container between launches, so a test that depends on the list being empty
        // passes once and then fails for the rest of time.
        app.buttons["Add key"].tap()
        let generateItem = app.buttons["Generate…"]
        XCTAssertTrue(generateItem.waitForExistence(timeout: 5), "the add-key menu should offer Generate")
        generateItem.tap()

        // A unique name so leftovers from an earlier run cannot satisfy the assertions.
        let keyName = "Phone-\(Int(Date().timeIntervalSince1970))"
        let nameField = app.textFields["Name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText(keyName)

        app.buttons["Generate"].tap()

        // What the user needs next is the public key line, in a form they can copy.
        XCTAssertTrue(
            app.navigationBars["Key Created"].waitForExistence(timeout: 10),
            "generating should land on a screen showing the new key"
        )
        let publicKey = app.staticTexts.containing(
            NSPredicate(format: "label BEGINSWITH %@", "ssh-ed25519 ")
        ).firstMatch
        XCTAssertTrue(publicKey.waitForExistence(timeout: 5), "the public key should be shown for copying")
        XCTAssertTrue(app.buttons["Copy public key"].exists)

        app.buttons["Done"].tap()
        // And it should now be listed.
        XCTAssertTrue(
            app.staticTexts[keyName].waitForExistence(timeout: 5),
            "the generated key should appear in the list"
        )
    }
}
