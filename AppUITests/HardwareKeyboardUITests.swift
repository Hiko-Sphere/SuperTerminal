import XCTest

/// Hardware-keyboard shortcuts, sent the way a physical keyboard sends them.
///
/// The app exposes a debug probe (`ST_UITEST_KEY_PROBE`) that counts the shortcuts it
/// performed. On this simulator the *first* modified key press of a run is always dropped
/// before the app ever sees it — `XCUIApplication.primeModifierKeys` spends it — and a
/// later one is occasionally dropped too; a shortcut that neither shows its result nor
/// moves the probe was lost that way and is sent once more, recorded as an attachment. A
/// shortcut that moved the probe and still showed nothing is a defect and fails.
@MainActor
final class HardwareKeyboardUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    static let textFieldKeysNotDelivered = "XCUITest typeKey does not deliver Escape or Return to a first-responder text field on the simulator (measured; the field's arrow key commands do arrive, and ⌘ keys arrive whatever is focused)"

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["ST_UITEST_RESET"] = "1"
        app.launchEnvironment["ST_UITEST_KEY_PROBE"] = "1"
        app.launch()
        XCTAssertTrue(app.navigationBars["Apex Terminal"].waitForExistence(timeout: 10))
        // The first modified key press of the run is discarded before the app sees it —
        // measured, see `XCUIApplication.primeModifierKeys`. Spending it here means the
        // retry below is left to cover the rarer case of a *second* loss, rather than
        // being the thing every one of these tests silently depends on.
        app.primeModifierKeys()
        return app
    }

    private func performed(_ app: XCUIApplication) -> (count: Int, last: String) {
        let probe = app.descendants(matching: .any).matching(identifier: "key-probe").firstMatch
        let parts = (probe.value as? String ?? "0/-").split(separator: "/", maxSplits: 1).map(String.init)
        return (Int(parts.first ?? "") ?? 0, parts.count > 1 ? parts[1] : "-")
    }

    private func press(_ key: String, modifiers: XCUIElement.KeyModifierFlags, in app: XCUIApplication,
                       expecting target: XCUIElement, _ what: String) {
        let before = performed(app).count
        app.typeKey(key, modifierFlags: modifiers)
        if target.waitForExistence(timeout: 3) { return }
        let after = performed(app)
        XCTAssertEqual(after.count, before, "\(what): the app performed \(after.last) and showed nothing — that is a defect")
        let note = XCTAttachment(string: "first \(key) with \(modifiers) never reached the app; sent again")
        note.lifetime = .keepAlways
        add(note)
        app.typeKey(key, modifierFlags: modifiers)
        XCTAssertTrue(target.waitForExistence(timeout: 5), "\(what) (probe after retry: \(performed(app)))")
    }

    func testCommandKOpensThePaletteAndEscapeClosesIt() throws {
        let app = launch()
        // The palette's own field, by identifier: the host list has a search field of its
        // own, and "first search field" matched that one and never went away.
        let query = app.textFields["palette-query"]
        press("k", modifiers: .command, in: app, expecting: query, "⌘K should open the command palette")
        // Escape and Return sent while a text field is first responder never arrive from
        // this instrument (the arrows do). Strict, so the day the simulator delivers them
        // this flips to a failure and the expectation comes out. Hardware check in
        // docs/RELEASE.md.
        XCTExpectFailure(Self.textFieldKeysNotDelivered, strict: true) {
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(query.waitForNonExistence(timeout: 5), "Escape should close the palette")
        }
    }

    func testCommandNOpensANewConnectionFromTheHostList() throws {
        let app = launch()
        // Nothing has focus on a fresh host list; the shortcut must still land.
        press("n", modifiers: .command, in: app, expecting: app.navigationBars["New Connection"], "⌘N should open the connection editor")
    }

    func testCommandCommaOpensSettings() throws {
        let app = launch()
        press(",", modifiers: .command, in: app, expecting: app.navigationBars["Settings"], "⌘, should open Settings")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForNonExistence(timeout: 5))
    }

    /// With the host list's search field focused, a hardware ⌘K still opens the palette.
    /// It did not when the shortcuts lived on a hidden first-responder view — a focused
    /// field is not on that view's responder chain — and this was a strict expected
    /// failure; as a SwiftUI shortcut in the hierarchy the field sits in, it arrives.
    /// Measured after the redesign: delivered on the first key in 8 of 8 runs on iPhone
    /// and 4 of 4 on iPad; one earlier full-suite run saw the simulator drop both the key
    /// and its retry (the probe showed the app received nothing), which is the instrument.
    func testCommandKWithTheSearchFieldFocused() throws {
        let app = launch()
        // On the iPad's sidebar the search field is hidden until the list is pulled.
        let search = app.searchFields.firstMatch
        if !search.waitForExistence(timeout: 3) {
            app.collectionViews.firstMatch.swipeDown()
        }
        guard search.waitForExistence(timeout: 5) else {
            throw XCTSkip("this layout exposes no search field to focus; the case is covered on iPhone")
        }
        search.tap()
        press("k", modifiers: .command, in: app, expecting: app.textFields["palette-query"], "⌘K with a focused field")
    }

    /// Return runs the highlighted item — the first is New Connection.
    func testReturnRunsTheHighlightedPaletteItem() throws {
        let app = launch()
        let query = app.textFields["palette-query"]
        press("k", modifiers: .command, in: app, expecting: query, "⌘K should open the command palette")
        XCTExpectFailure(Self.textFieldKeysNotDelivered, strict: true) {
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(app.navigationBars["New Connection"].waitForExistence(timeout: 5), "Return should run the first item")
        }
    }

    /// Down moves the highlight, so Return runs the second item instead of the first.
    func testDownArrowMovesThePaletteSelection() throws {
        let app = launch()
        let query = app.textFields["palette-query"]
        press("k", modifiers: .command, in: app, expecting: query, "⌘K should open the command palette")
        // The highlight itself is asserted: the second row carries the selected trait. The
        // arrows are key commands on the field and do arrive — unlike Escape and Return.
        app.typeKey(.downArrow, modifierFlags: [])
        let second = app.buttons["palette-action-keyrow"].firstMatch
        XCTAssertTrue(second.waitForExistence(timeout: 3))
        XCTAssertTrue(second.isSelected, "↓ should move the highlight to the second item")
    }
}
