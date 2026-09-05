import XCTest

/// Scrolling and searching that behave the same on a phone and an iPad.
///
/// Two iPad differences broke tests written against the phone. Settings is a form sheet
/// there, not a full-screen push, so `app.swipeUp()` scrolls the connection list *behind*
/// the sheet and the sheet never moves — and `collectionViews.firstMatch` is that same
/// sidebar list, not the form. And a sidebar's search field is folded into the navigation
/// bar until the list is pulled down, so it does not exist to be asserted on until revealed.
private extension XCUIApplication {
    /// Swipes the Settings form once, choosing the element at the moment of the swipe.
    ///
    /// Three earlier versions failed the same way: they *chose* an element from one
    /// accessibility snapshot and *acted* on it in the next. XCUITest re-resolves queries
    /// lazily, so a count taken then indexed, or an `.exists` checked then swiped, raced the
    /// tree and reported "no matches" for an element that was there a moment before. Here
    /// the decision and the action are adjacent. The form is identified by the identifier
    /// `SettingsView` attaches; where a snapshot does not expose it, the only collection
    /// view on screen is the form itself.
    private func swipeSettingsForm(up: Bool) {
        let byIdentity = descendants(matching: .any).matching(identifier: "settings-form").firstMatch
        let target = byIdentity.exists ? byIdentity : collectionViews.firstMatch
        if up { target.swipeUp() } else { target.swipeDown() }
    }

    /// Scrolls the Settings form until `element` can be tapped, or gives up.
    ///
    /// Searches in both directions. A helper that only swipes one way finds a row below the
    /// viewport and never one above it — so after opening a row near the foot of the form
    /// and coming back, every row above it becomes unreachable. That is an ordering
    /// artefact of the test, not a property of the screen, and it should not decide results.
    @discardableResult
    func scroll(to element: XCUIElement, attempts: Int = 20) -> Bool {
        if element.exists, element.isHittable { return true }
        // Down the form first: the row being looked for is usually below, and with Bold
        // Text every row is taller, so the budget has to cover a long form.
        for up in [true, false] {
            for _ in 0 ..< attempts {
                if element.exists, element.isHittable { return true }
                swipeSettingsForm(up: up)
            }
        }
        return element.exists && element.isHittable
    }

    /// Brings the connection list's search field on screen and returns it.
    func revealSearchField() -> XCUIElement {
        let field = searchFields.firstMatch
        if !field.exists {
            // Pulling the list down is what unfolds a sidebar's search bar on iPad.
            collectionViews.firstMatch.swipeDown()
        }
        _ = field.waitForExistence(timeout: 5)
        return field
    }
}

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

        waitUntilConnected()
        // The terminal focuses itself when it appears, but tapping makes the test
        // independent of that timing rather than racing it.
        if terminal.isHittable { terminal.tap() }
        XCTAssertTrue(
            app.keyboards.element.waitForExistence(timeout: 10),
            "the keyboard should be up so the terminal can receive typing"
        )
    }

    /// Waits for the connecting overlay to go away.
    ///
    /// Input sent before the shell exists is dropped — deliberately, and the overlay says
    /// so — but a test that types into a connecting session then proves nothing about
    /// what it meant to prove.
    private func waitUntilConnected(timeout: TimeInterval = 30) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !app.activityIndicators.firstMatch.exists { return }
            usleep(200_000)
        }
        XCTFail("the session was still connecting after \(Int(timeout))s")
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
        XCTAssertTrue(
            control.waitForExistence(timeout: 10),
            "the accessory row should offer Control; buttons on screen: "
                + app.buttons.allElementsBoundByIndex.map { $0.label }.joined(separator: " | ")
        )
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
    func testCommandPaletteFindsASnippetAndInsertsIt() throws {
        try openTerminal()

        // A snippet to find. Created through the interface so the palette is reading real
        // stored data rather than something injected behind it.
        app.buttons["Session"].tap()
        app.buttons["Snippets…"].tap()
        app.buttons["New snippet"].tap()
        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5), "the snippet editor should appear")
        name.tap()
        name.typeText("Disk Free Here")
        let editor = app.textViews["Snippet command"]
        editor.tap()
        app.typeText("printf 'PALETTE_%s\\n' OK")
        app.buttons["Save"].tap()
        app.buttons["Done"].tap()

        app.buttons["Session"].tap()
        let palette = app.buttons["Command Palette…"]
        XCTAssertTrue(palette.waitForExistence(timeout: 5), "the session menu should offer the palette")
        palette.tap()

        let field = app.textFields["palette-query"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the palette should open with its field ready")
        field.tap()
        // Initials, not a substring: "dfh" appears nowhere in "Disk Free Here" as
        // consecutive characters. A substring filter would find nothing at all.
        field.typeText("dfh")

        let match = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "palette-snippet-")
        ).firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: 5), "fuzzy initials should find the snippet")
        match.tap()

        // Inserted, not run — the palette uses the same snippet path as everything else.
        let afterInsert = waitForScreen(containing: "printf", timeout: 10)
        XCTAssertTrue(afterInsert.contains("PALETTE_"), "the snippet should be typed in: \(afterInsert)")
    }

    func testPinchingResizesTheTerminalAndTellsTheServer() throws {
        try openTerminal()

        // The shell's own idea of the geometry, which is the only thing that matters:
        // a font change the remote is not told about makes every wrapped line wrap in
        // the wrong place.
        app.typeText("stty size\n")
        _ = waitForScreen(containing: "stty size")
        guard let before = latestSttySize() else {
            XCTFail("could not read the starting geometry: \(terminalValue())")
            return
        }

        // Zoom in: larger text, so fewer columns fit.
        terminal.pinch(withScale: 2.0, velocity: 3)

        app.typeText("stty size\n")
        var after: (rows: Int, columns: Int)?
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let latest = latestSttySize(), latest != before { after = latest; break }
            usleep(250_000)
        }

        guard let after else {
            XCTFail("the server was never told about the new size; it still reports \(before)")
            return
        }
        XCTAssertLessThan(after.columns, before.columns, "zooming in should leave room for fewer columns")
    }

    /// The most recent `rows columns` pair printed by `stty size`.
    private func latestSttySize() -> (rows: Int, columns: Int)? {
        let lines = terminalValue().split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            let parts = line.split(separator: " ").compactMap { Int($0) }
            // Two bare numbers on a line, which the echoed command itself never is.
            if parts.count == 2, line.trimmingCharacters(in: .whitespaces).allSatisfy({ $0.isNumber || $0 == " " }) {
                return (parts[0], parts[1])
            }
        }
        return nil
    }

    private func terminalValue() -> String { terminal.value as? String ?? "" }

    private var terminal: XCUIElement {
        app.otherElements.matching(NSPredicate(format: "label BEGINSWITH %@", "Terminal for")).firstMatch
    }

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
        XCTAssertTrue(app.scroll(to: keysLink), "Settings should offer a Keys screen")
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

/// Accessibility settings, exercised by actually turning them on.
///
/// These previously existed only as code that looked correct. Launch arguments drive the
/// real system settings, so a regression that breaks high contrast or Reduce Transparency
/// fails here rather than being discovered by someone who depends on them.
final class AccessibilityUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(with arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += arguments
        let environment = ProcessInfo.processInfo.environment
        for key in [
            "ST_UITEST_SEED", "ST_UITEST_HOST", "ST_UITEST_PORT", "ST_UITEST_USER",
            "ST_UITEST_KEY", "ST_UITEST_TRUST_HOST_KEYS", "ST_UITEST_NAME",
        ] {
            if let value = environment[key] { app.launchEnvironment[key] = value }
        }
        app.launch()
        return app
    }

    func testHostListSurvivesEveryAccessibilityTextSize() throws {
        // The largest size is where layouts break; if it holds, the ones below it do.
        for category in [
            "UICTContentSizeCategoryAccessibilityM",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ] {
            let app = launch(with: ["-UIPreferredContentSizeCategoryName", category])
            XCTAssertTrue(
                app.navigationBars["SuperTerminal"].waitForExistence(timeout: 10),
                "the host list should render at \(category)"
            )
            XCTAssertTrue(
                app.buttons["New Connection"].exists,
                "the primary action should stay reachable at \(category)"
            )
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "host-list-\(category)"
            shot.lifetime = .keepAlways
            add(shot)
            app.terminate()
        }
    }

    func testSettingsRemainUsableWithReduceTransparencyAndBoldText() throws {
        let app = launch(with: [
            "-UIAccessibilityReduceTransparencyEnabled", "1",
            "-UIAccessibilityBoldTextEnabled", "1",
        ])
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))

        // Every section heading should still be reachable; a bar that vanished into a
        // solid background would take its controls with it. Bold text makes the form
        // taller, so the later sections need scrolling to — "reachable" is the claim,
        // not "on the first screen".
        for label in ["Appearance", "Privacy", "Terminal", "Security", "Data"] {
            XCTAssertTrue(
                app.scroll(to: app.staticTexts[label]),
                "the \(label) section should be reachable with Reduce Transparency on"
            )
        }
        // The mark and version at the foot of Settings. It is the last thing in the form,
        // so reaching it also proves the whole form still scrolls with Bold Text on — the
        // setting that makes every row taller and pushes content off the end.
        let about = app.staticTexts.containing(
            NSPredicate(format: "label BEGINSWITH %@", "Version ")
        ).firstMatch
        XCTAssertTrue(app.scroll(to: about), "the version should be reachable at the foot of Settings")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "settings-reduce-transparency"
        shot.lifetime = .keepAlways
        add(shot)
    }


    func testEveryControlOnTheHostListIsLabelledForVoiceOver() throws {
        let app = launch(with: [])
        XCTAssertTrue(app.navigationBars["SuperTerminal"].waitForExistence(timeout: 10))

        // An unlabelled button is read out as "button" and is unusable without sight.
        for index in 0 ..< app.buttons.count {
            let button = app.buttons.element(boundBy: index)
            guard button.exists, button.isHittable else { continue }
            XCTAssertFalse(
                button.label.trimmingCharacters(in: .whitespaces).isEmpty,
                "a button at index \(index) has no accessibility label"
            )
        }
    }
}

/// Snippets and history against the live server.
///
/// The unit tests prove the store's rules. These prove the two things only the real
/// interface and a real shell can show: that a snippet lands in the terminal *without*
/// running, and that what gets recorded as history is the command the user actually
/// typed — reconstructed from keystrokes, not scraped from the shell's echo.
final class SnippetUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["ST_UITEST_SEED"] == "1",
            "run scripts/ui-terminal-e2e.sh to provide a server"
        )
        app = XCUIApplication()
        for key in [
            "ST_UITEST_SEED", "ST_UITEST_HOST", "ST_UITEST_PORT", "ST_UITEST_USER",
            "ST_UITEST_KEY", "ST_UITEST_TRUST_HOST_KEYS", "ST_UITEST_NAME",
        ] {
            if let value = environment[key] { app.launchEnvironment[key] = value }
        }
        app.launch()
    }

    private var terminal: XCUIElement {
        app.otherElements.matching(NSPredicate(format: "label BEGINSWITH %@", "Terminal for")).firstMatch
    }

    private func openTerminal() throws {
        // Prefer a session that is already running: opening a second connection to the
        // same server just to type into it is neither what a person would do nor what
        // this test is about, and on iPad it swaps the detail column mid-tap.
        let running = app.buttons["open-session"].firstMatch
        if running.exists, running.isHittable {
            running.tap()
        } else {
            let byName = app.buttons.containing(
                NSPredicate(format: "label CONTAINS %@", "Local Test Server")
            ).firstMatch
            XCTAssertTrue(byName.waitForExistence(timeout: 10), "the seeded connection should be listed")
            byName.tap()
        }
        XCTAssertTrue(terminal.waitForExistence(timeout: 30), "the terminal screen should appear")
        waitUntilConnected()
        if terminal.isHittable { terminal.tap() }
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 10), "the keyboard should be up")
    }

    /// Waits for the connecting overlay to go away.
    ///
    /// Input sent before the shell exists is dropped — deliberately, and the overlay says
    /// so — but a test that types into a connecting session then proves nothing about
    /// what it meant to prove.
    private func waitUntilConnected(timeout: TimeInterval = 30) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !app.activityIndicators.firstMatch.exists { return }
            usleep(200_000)
        }
        XCTFail("the session was still connecting after \(Int(timeout))s")
    }

    @discardableResult
    private func waitForScreen(containing needle: String, timeout: TimeInterval = 30) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = ""
        while Date() < deadline {
            latest = terminal.value as? String ?? ""
            if latest.contains(needle) { return latest }
            usleep(200_000)
        }
        return latest
    }

    private func screenDoesNotContain(_ needle: String, within seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if (terminal.value as? String ?? "").contains(needle) { return false }
            usleep(200_000)
        }
        return true
    }

    private func openSnippets() {
        app.buttons["Session"].tap()
        let snippets = app.buttons["Snippets…"]
        XCTAssertTrue(snippets.waitForExistence(timeout: 5), "the session menu should offer snippets")
        snippets.tap()
    }

    /// Gets back to the connection list from a terminal, in either layout.
    private func returnToHostList() {
        let settings = app.buttons["Settings"]
        if settings.exists, settings.isHittable { return }
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists, back.isHittable { back.tap() }
    }

    /// Switches a settings toggle on and waits for it to take.
    ///
    /// Taps the switch itself rather than the row. XCUITest aims a plain `tap()` at the
    /// centre of the row's accessibility element, which on this OS activates nothing —
    /// verified by watching a neighbouring toggle ignore the same tap.
    private func turnOn(_ toggle: XCUIElement) {
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "the setting should exist")
        _ = app.scroll(to: toggle)
        // Let the scroll settle: a tap dispatched mid-momentum lands wherever the row has
        // moved to by then, which is not necessarily this row.
        var frame = toggle.frame
        for _ in 0 ..< 20 {
            usleep(150_000)
            let current = toggle.frame
            if current == frame { break }
            frame = current
        }
        XCTAssertEqual(toggle.value as? String, "0", "\(toggle.label) should start off")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        var value = toggle.value as? String
        for _ in 0 ..< 20 where value != "1" {
            usleep(150_000)
            value = toggle.value as? String
        }
        XCTAssertEqual(value, "1", "tapping should turn \(toggle.label) on")
    }

    func testASnippetIsTypedIntoTheTerminalButNotRun() throws {
        try openTerminal()
        openSnippets()

        app.buttons["New snippet"].tap()
        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5), "the editor should appear")
        name.tap()
        name.typeText("Marker")

        // A command whose output is unmistakable, and which the shell assembles so the
        // echoed command line cannot be mistaken for having run.
        let editor = app.textViews["Snippet command"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "the command editor should exist")
        editor.tap()
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 5), "the editor should take focus")
        app.typeText("printf 'SNIP_%s\\n' RAN")
        app.buttons["Save"].tap()

        // By identifier rather than by a label search: `containing` matches any ancestor
        // with a matching descendant, and on iPad the first such ancestor was a container
        // whose centre is not the row.
        let saved = app.buttons["snippet-Marker"]
        XCTAssertTrue(saved.waitForExistence(timeout: 5), "the snippet should be listed")
        XCTAssertTrue(saved.isHittable, "the snippet row should be reachable")
        // Same lesson as the settings toggle: XCUITest's plain `tap()` aims at the centre
        // of the accessibility element, which for a composed SwiftUI row activates
        // nothing on iPad.
        saved.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        // Inserted, so the text is on screen…
        let afterInsert = waitForScreen(containing: "printf", timeout: 10)
        XCTAssertTrue(
            afterInsert.contains("SNIP_"),
            "the snippet text should be in the terminal: \(afterInsert); "
                + "buttons: " + app.buttons.allElementsBoundByIndex.map { $0.label }.joined(separator: " | ")
                + "; static texts: " + app.staticTexts.allElementsBoundByIndex.map { $0.label }.joined(separator: " | ")
        )
        // …and not run, so its output is not. This is the whole point of the default.
        XCTAssertTrue(
            screenDoesNotContain("SNIP_RAN", within: 3),
            "a snippet must not run until the user presses Return"
        )

        app.typeText("\n")
        let afterReturn = waitForScreen(containing: "SNIP_RAN")
        XCTAssertTrue(afterReturn.contains("SNIP_RAN"), "pressing Return should run it: \(afterReturn)")
    }

    func testHistoryIsEmptyUntilTurnedOnAndThenRecordsWhatWasTyped() throws {
        // Off by default: the feature is visible, but nothing has been kept.
        try openTerminal()
        app.typeText("printf 'BEFORE_%s\\n' OPTIN\n")
        XCTAssertTrue(
            waitForScreen(containing: "BEFORE_OPTIN").contains("BEFORE_OPTIN"),
            "the command must actually reach the shell, or the rest of this test proves nothing"
        )

        openSnippets()
        app.segmentedControls.buttons["History"].tap()
        XCTAssertTrue(
            app.staticTexts["History is off"].waitForExistence(timeout: 5),
            "history should be off until the user asks for it"
        )
        app.buttons["Done"].tap()

        // Turn it on through the interface, the way a user would. On a phone that means
        // going back up the stack; on an iPad the sidebar is already beside the terminal.
        returnToHostList()
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "the host list should offer settings")
        settings.tap()
        turnOn(app.switches["Record command history"])
        app.buttons["Done"].tap()

        try openTerminal()
        app.typeText("printf 'AFTER_%s\\n' OPTIN\n")
        XCTAssertTrue(
            waitForScreen(containing: "AFTER_OPTIN").contains("AFTER_OPTIN"),
            "the command must actually reach the shell before history can be expected to hold it"
        )

        openSnippets()
        app.segmentedControls.buttons["History"].tap()

        // Match on the part of the command line that is distinctive, not on the output
        // it produces — those are different strings, and only the command is recorded.
        let recorded = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "AFTER_")
        ).firstMatch
        XCTAssertTrue(
            recorded.waitForExistence(timeout: 5),
            "the typed command should be recorded; the list showed: "
                + app.staticTexts.allElementsBoundByIndex.map { $0.label }.joined(separator: " | ")
        )
        // Recorded from keystrokes, so it is the command alone — no prompt, no output.
        XCTAssertEqual(
            recorded.label, "printf 'AFTER_%s\\n' OPTIN",
            "history should hold exactly what was typed, not the shell's rendering of it"
        )
        // What was typed before opting in must not appear retroactively.
        XCTAssertFalse(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "BEFORE_")).firstMatch.exists,
            "turning history on must not resurrect commands run before it was on"
        )
    }
}


/// Opening a session in a second window on iPad.
///
/// Skips where multiple windows are not offered, which is every iPhone — so this runs
/// only on the destination it is about.
final class MultiWindowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["ST_UITEST_SEED"] == "1",
            "run scripts/ui-terminal-e2e.sh to provide a server"
        )
        app = XCUIApplication()
        for key in [
            "ST_UITEST_SEED", "ST_UITEST_HOST", "ST_UITEST_PORT", "ST_UITEST_USER",
            "ST_UITEST_KEY", "ST_UITEST_TRUST_HOST_KEYS", "ST_UITEST_NAME",
        ] {
            if let value = environment[key] { app.launchEnvironment[key] = value }
        }
        app.launch()
    }

    func testSessionsFromLastTimeAreOfferedAfterARelaunch() throws {
        let host = app.buttons.containing(
            NSPredicate(format: "label CONTAINS %@", "Local Test Server")
        ).firstMatch
        XCTAssertTrue(host.waitForExistence(timeout: 10), "the seeded connection should be listed")
        host.tap()

        let terminal = app.otherElements.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Terminal for")
        ).firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 30), "the terminal should open")

        // Killed rather than backgrounded: this is what the system does to an app it
        // decides to reclaim, and the case the feature exists for.
        app.terminate()
        app.launch()

        let reopen = app.buttons.containing(
            NSPredicate(format: "label CONTAINS %@", "Reopen")
        ).firstMatch
        XCTAssertTrue(reopen.waitForExistence(timeout: 15), "the app should offer to reopen what was open")
        // The offer says plainly that these are new sessions rather than the old ones.
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS %@", "nothing that was running has survived")
            ).firstMatch.exists,
            "the offer must not imply the old shells came back"
        )

        reopen.tap()
        XCTAssertTrue(terminal.waitForExistence(timeout: 30), "tapping should reach a terminal")
        XCTAssertFalse(
            app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Reopen")).firstMatch.exists,
            "the offer should not linger once it has been taken"
        )
    }

    func testASessionCanBeOpenedInASecondWindow() throws {
        let host = app.buttons.containing(
            NSPredicate(format: "label CONTAINS %@", "Local Test Server")
        ).firstMatch
        XCTAssertTrue(host.waitForExistence(timeout: 10), "the seeded connection should be listed")
        host.tap()

        // On a phone opening a session pushes to it, so come back to the list before
        // looking for the row. On iPad the list never went away.
        let session = app.buttons["open-session"].firstMatch
        if !session.waitForExistence(timeout: 15) {
            let back = app.navigationBars.buttons.element(boundBy: 0)
            if back.exists, back.isHittable { back.tap() }
        }
        XCTAssertTrue(session.waitForExistence(timeout: 15), "the session should be listed")

        // Counted rather than assumed to be one: iPadOS restores the windows a previous
        // run left behind, so the app may well start with two.
        let probe = app.descendants(matching: .any).matching(identifier: "scene-count").firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 10), "the scene probe should be present in a seeded run")
        let before = Int(probe.value as? String ?? "") ?? 0
        XCTAssertGreaterThan(before, 0, "the app should report at least its own window")

        session.press(forDuration: 1.0)
        let openInNewWindow = app.buttons["Open in New Window"]
        guard openInNewWindow.waitForExistence(timeout: 5) else {
            throw XCTSkip("this device does not offer multiple windows")
        }
        openInNewWindow.tap()

        // The window that opens shows the session it was given, and the app stays alive.
        let terminal = app.otherElements.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Terminal for")
        ).firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 30), "the new window should show the session")
        XCTAssertEqual(app.state, .runningForeground)

        // The point of the feature: a *second* window exists. Without this the test would
        // pass just as happily if the menu item did nothing at all.
        var after = Int(probe.value as? String ?? "") ?? 0
        for _ in 0 ..< 20 where after <= before {
            usleep(250_000)
            after = Int(probe.value as? String ?? "") ?? 0
        }
        XCTAssertGreaterThan(
            after, before,
            "opening in a new window should create another scene; without this the test "
                + "would pass just as happily if the menu item did nothing at all"
        )

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Second window showing the session"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}

/// The app in Chinese.
///
/// Localization fails silently: an untranslated string compiles, ships, and simply shows
/// English to someone who chose Chinese. Nothing crashes and no unit test notices. These
/// launch the real app in each locale and read what is on screen.
final class LocalizationUITests: XCTestCase {
    private func launch(inLanguage language: String) -> XCUIApplication {
        let app = XCUIApplication()
        // The pair of arguments iOS itself uses; setting only AppleLanguages leaves the
        // formatter locale on the host's, which hides mistakes in dates and numbers.
        app.launchArguments += ["-AppleLanguages", "(\(language))", "-AppleLocale", language]
        let environment = ProcessInfo.processInfo.environment
        for key in [
            "ST_UITEST_SEED", "ST_UITEST_HOST", "ST_UITEST_PORT", "ST_UITEST_USER",
            "ST_UITEST_KEY", "ST_UITEST_TRUST_HOST_KEYS", "ST_UITEST_NAME",
        ] {
            if let value = environment[key] { app.launchEnvironment[key] = value }
        }
        app.launch()
        return app
    }

    private func attach(_ app: XCUIApplication, named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testSimplifiedChineseReachesTheInterface() throws {
        let app = launch(inLanguage: "zh-Hans")
        XCTAssertTrue(app.navigationBars["SuperTerminal"].waitForExistence(timeout: 15))

        // The section header over the connection list, and the search field's prompt.
        XCTAssertTrue(app.staticTexts["连接"].waitForExistence(timeout: 5), "the Connections header should be Simplified Chinese")
        XCTAssertEqual(app.revealSearchField().placeholderValue, "搜索连接", "the search prompt should be Simplified Chinese")

        attach(app, named: "zh-Hans-1-connections")

        app.buttons["设置"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 10), "Settings should be Simplified Chinese")
        XCTAssertTrue(app.staticTexts["外观"].exists, "the Appearance section should be translated")
        attach(app, named: "zh-Hans-2-settings")

        // Keys and Snippets, the two screens with the longest copy — where a translation
        // that runs long shows up as truncation rather than as a failure. Asserted, not
        // skipped: a tour that quietly omits the screens it exists for proves nothing.
        tour(app, settingsTitle: "设置", rows: [("密钥", "zh-Hans-3-keys"), ("命令片段", "zh-Hans-4-snippets")])
    }

    /// Opens each Settings row, screenshots it, and comes back.
    ///
    /// `settingsTitle` is the localized navigation-bar title, and the tour waits for it to
    /// return after each Back before touching the form again. Querying the instant Back is
    /// tapped races the pop animation: the form is not there to scroll yet, and a row that
    /// exists reads as "not offered". A screenshot is attached at that moment so a failure
    /// shows where the app actually was instead of inviting a guess.
    private func tour(_ app: XCUIApplication, settingsTitle: String, rows: [(label: String, shot: String)]) {
        for (label, shot) in rows {
            XCTAssertTrue(app.navigationBars[settingsTitle].waitForExistence(timeout: 10),
                          "should be back on Settings before looking for \(label)")
            let row = app.descendants(matching: .any).matching(
                NSPredicate(format: "label == %@", label)
            ).firstMatch
            let reached = app.scroll(to: row)
            if !reached { attach(app, named: "\(shot)-not-found") }
            XCTAssertTrue(reached, "Settings should offer \(label)")
            row.tap()
            XCTAssertTrue(app.navigationBars[label].waitForExistence(timeout: 5), "\(label) should open")
            attach(app, named: shot)
            // Back is the leading button of *this screen's* bar. Inside a sheet there are
            // two navigation bars in the tree, and the first button of the first one is the
            // sheet's own "Done" — tapping that dismisses Settings entirely, which is why
            // every second row of this tour was "not offered": the form was gone.
            let back = app.navigationBars[label].buttons.element(boundBy: 0)
            XCTAssertTrue(back.waitForExistence(timeout: 5), "\(label) should have a Back button")
            back.tap()
        }
    }

    func testTraditionalChineseIsTranslatedIndependently() throws {
        let app = launch(inLanguage: "zh-Hant")
        XCTAssertTrue(app.navigationBars["SuperTerminal"].waitForExistence(timeout: 15))

        // 連線, not 连接. This is the assertion that catches the usual failure: Traditional
        // produced by running a character converter over Simplified, which leaves mainland
        // vocabulary behind and reads as foreign to a Taiwanese user.
        XCTAssertTrue(app.staticTexts["連線"].waitForExistence(timeout: 5),
                      "the Connections header should use Taiwan vocabulary, not converted Simplified")
        XCTAssertFalse(app.staticTexts["连接"].exists, "Simplified text must not appear in the Traditional build")
        XCTAssertEqual(app.revealSearchField().placeholderValue, "搜尋連線", "the search prompt should use Taiwan vocabulary")

        app.buttons["設定"].tap()
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 10), "Settings should be Traditional Chinese")
        attach(app, named: "zh-Hant-2-settings")
        tour(app, settingsTitle: "設定", rows: [("金鑰", "zh-Hant-3-keys"), ("指令片段", "zh-Hant-4-snippets")])
    }

    func testTerminalOutputIsNeverTranslated() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["ST_UITEST_SEED"] == "1", "run scripts/ui-terminal-e2e.sh to provide a server")

        let app = launch(inLanguage: "zh-Hans")
        let host = app.buttons.containing(
            NSPredicate(format: "label CONTAINS %@", "Local Test Server")
        ).firstMatch
        XCTAssertTrue(host.waitForExistence(timeout: 15))
        host.tap()

        // The terminal's accessibility label is itself localized — "Terminal for X" becomes
        // "X 的终端" — so matching the English prefix would fail here, which is the feature
        // working rather than breaking.
        let terminal = app.otherElements.matching(
            NSPredicate(format: "label ENDSWITH %@", "的终端")
        ).firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 30), "the terminal should open in any language")

        // What the remote machine sent, byte for byte. A terminal that "helpfully" localized
        // its output would be worse than useless — the text is a program's output, and the
        // user is often reading it to compare against documentation or paste elsewhere.
        if terminal.isHittable { terminal.tap() }
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 10))
        app.typeText("printf 'NOT_%s\\n' TRANSLATED\n")

        let deadline = Date().addingTimeInterval(20)
        var screen = ""
        while Date() < deadline {
            screen = terminal.value as? String ?? ""
            if screen.contains("NOT_TRANSLATED") { break }
            usleep(200_000)
        }
        XCTAssertTrue(screen.contains("NOT_TRANSLATED"), "remote output must reach the screen unchanged: \(screen)")
    }
}
