import XCTest

/// Making a theme, giving one connection its own, and deleting the theme again (D-079).
///
/// The app has been able to *hold* a custom theme since it had themes at all, and to read a
/// per-connection override — with nothing anywhere able to write either. So the run worth making
/// is the whole loop, ending on the part that goes wrong silently: deleting a theme a connection
/// is using has to put that connection back on the default rather than leave it addressing an id
/// that resolves to nothing.
@MainActor
final class ThemeUITests: XCTestCase {
    private lazy var app: XCUIApplication = {
        let environment = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        for key in [
            "ST_UITEST_SEED", "ST_UITEST_HOST", "ST_UITEST_PORT", "ST_UITEST_USER",
            "ST_UITEST_KEY", "ST_UITEST_TRUST_HOST_KEYS", "ST_UITEST_NAME",
        ] {
            if let value = environment[key] { app.launchEnvironment[key] = value }
        }
        app.launch()
        return app
    }()

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["ST_UITEST_SEED"] == "1",
            "run scripts/ui-terminal-e2e.sh to provide a seeded connection"
        )
    }

    func testAThemeIsMadeGivenToAConnectionAndTakenBackAgain() throws {
        openSettings()

        // A row below the fold is not merely off screen — it is absent from the accessibility
        // tree, so every row here has to be scrolled to before it can be asked about (D-068).
        let themes = try scrolled(to: app.buttons["settings-themes"])
        themes.tap()
        XCTAssertTrue(app.navigationBars["Themes"].waitForExistence(timeout: 5))

        // Nothing of the user's own yet: the app has always shipped three themes and no way
        // to make a fourth.
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "theme-workshop-empty")
                .firstMatch.waitForExistence(timeout: 5),
            "the workshop should say there are none yet"
        )

        // Start from a built-in one. That must copy rather than edit: the built-ins are what
        // everything falls back to.
        let startFrom = try scrolled(to: app.buttons["theme-start-from-midnight"])
        startFrom.tap()

        // The editor opens on the new theme, with the palette on screen the whole time — the
        // point of editing a terminal theme is that "is this readable" is not answerable from
        // a swatch.
        let name = app.textFields["theme-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10), "the new theme should open in its editor")
        XCTAssertTrue(app.otherElements["theme-preview"].exists, "the editor should show the theme")

        // The measured readout is the differentiator: every terminal with a theme editor lets
        // you build a palette you cannot read and says nothing.
        //
        // Matched across every element type rather than as a `staticText`: the row is a
        // combined accessibility element, and which class XCUITest files that under is not
        // something to depend on. Asked for by label, because the label is what a person hears.
        let measured = try scrolled(
            to: app.descendants(matching: .any).matching(identifier: "theme-contrast-text").firstMatch
        )
        let ratio = measured.label + " " + (measured.value as? String ?? "")
        XCTAssertTrue(ratio.contains(":1"), "the readout should be a contrast ratio, got “\(ratio)”")

        // Rename it to something this test can find later.
        name.tap()
        name.press(forDuration: 1.2)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        name.typeText("Production Red")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Themes"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts["Production Red"].waitForExistence(timeout: 5),
            "the renamed theme should be in the list"
        )

        // Out of Settings and into a connection.
        closeSettings()

        let row = app.buttons.matching(identifier: "host-row")
            .matching(NSPredicate(format: "label CONTAINS %@", "Local Test Server")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        for _ in 0 ..< 20 where !row.isHittable { usleep(150_000) }
        row.press(forDuration: 1.0)
        let edit = app.buttons["Edit Connection"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()
        XCTAssertTrue(app.navigationBars["Edit Connection"].waitForExistence(timeout: 5))

        // The picker that had no way to exist: `Host.themeID` was read by the terminal and
        // written by nothing.
        // Read off the label rather than the value: a SwiftUI menu picker publishes its
        // selection as part of the label — "Theme, Same as Settings" — which is also what a
        // person using VoiceOver hears, so it is the right thing to assert on.
        let picker = try scrolled(to: app.buttons["host-theme"])
        XCTAssertTrue(
            picker.label.contains("Same as Settings"),
            "a connection follows Settings until told otherwise, got “\(picker.label)”"
        )
        picker.tap()
        let option = app.buttons["Production Red"].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), "the theme just made should be offered")
        option.tap()
        XCTAssertTrue(try scrolled(to: app.buttons["host-theme"]).label.contains("Production Red"))

        app.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Edit Connection"].waitForNonExistence(timeout: 5))

        // Reopen: the choice was saved rather than only shown.
        for _ in 0 ..< 20 where !row.isHittable { usleep(150_000) }
        row.press(forDuration: 1.0)
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()
        XCTAssertTrue(app.navigationBars["Edit Connection"].waitForExistence(timeout: 5))
        XCTAssertTrue(try scrolled(to: app.buttons["host-theme"]).label.contains("Production Red"))
        app.buttons["Cancel"].tap()

        // Now delete the theme. The confirmation has to say what it costs — which connection
        // loses its colour — before it is spent.
        openSettings()
        try scrolled(to: app.buttons["settings-themes"]).tap()
        XCTAssertTrue(app.navigationBars["Themes"].waitForExistence(timeout: 5))

        // Through the editor rather than the row's swipe action: a swipe depends on gesture
        // thresholds a test cannot see, and the editor is where somebody looking at a theme
        // actually is when they decide to be rid of it.
        let themeRow = app.buttons.containing(
            NSPredicate(format: "label CONTAINS %@", "Production Red")
        ).firstMatch
        XCTAssertTrue(themeRow.waitForExistence(timeout: 5))
        themeRow.tap()
        try scrolled(to: app.buttons["theme-delete"]).tap()

        let warning = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "Local Test Server")
        ).firstMatch
        XCTAssertTrue(
            warning.waitForExistence(timeout: 5),
            "the confirmation should name the connection that is about to lose its colour"
        )
        app.buttons["Delete"].firstMatch.tap()

        // And the connection is put back rather than left pointing at nothing. Without the
        // repointing step the picker here would read "Not on this device" — the resolver
        // falls back silently, so nobody would ever be told.
        closeSettings()
        for _ in 0 ..< 20 where !row.isHittable { usleep(150_000) }
        row.press(forDuration: 1.0)
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()
        XCTAssertTrue(app.navigationBars["Edit Connection"].waitForExistence(timeout: 5))
        let afterDeletion = try scrolled(to: app.buttons["host-theme"]).label
        XCTAssertTrue(
            afterDeletion.contains("Same as Settings"),
            "deleting the theme should put the connection back, got “\(afterDeletion)”"
        )
        // And not still naming the theme that is gone, nor reporting it as missing — either
        // would mean the repointing step did not run.
        XCTAssertFalse(afterDeletion.contains("Production Red"), "the deleted theme is still named")
        XCTAssertFalse(afterDeletion.contains("Not on this device"), "the connection was left addressing nothing")
    }

    // MARK: - Helpers

    private func openSettings() {
        if !app.buttons["settings-open"].exists {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        XCTAssertTrue(app.buttons["settings-open"].waitForExistence(timeout: 10))
        app.buttons["settings-open"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }

    /// Back out of any sub-screen, then out of Settings itself.
    private func closeSettings() {
        for _ in 0 ..< 4 where !app.navigationBars["Settings"].exists {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            _ = app.navigationBars["Settings"].waitForExistence(timeout: 3)
        }
        let done = app.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: 3) { done.tap() }
        XCTAssertTrue(app.navigationBars["Settings"].waitForNonExistence(timeout: 5))
    }

    /// Scrolls until the element is both present and reachable.
    ///
    /// Two separate conditions, and both are needed: a row below the fold does not exist in
    /// the tree at all, and a row that has just come into it can still be under a toolbar.
    ///
    /// The swipe goes to the frontmost scrollable rather than to `app`. On an iPad, Settings
    /// and everything pushed inside it is a form sheet, and `app.swipeUp()` scrolls the
    /// connection list *behind* that sheet — the sheet never moves, and the row being looked
    /// for never arrives. Naming the containers is what makes the gesture land where the
    /// content is.
    @discardableResult
    private func scrolled(to element: XCUIElement, attempts: Int = 14) throws -> XCUIElement {
        for _ in 0 ..< attempts {
            if element.exists, element.isHittable { return element }
            scrollable().swipeUp()
        }
        if !element.exists { add(XCTAttachment(string: app.debugDescription)) }
        XCTAssertTrue(element.exists && element.isHittable, "could not reach \(element)")
        return element
    }

    /// The innermost screen currently on top, by identifier — deepest first, since a pushed
    /// screen sits over the one that pushed it.
    private func scrollable() -> XCUIElement {
        // `exists` only. A collection view is a container: it reports no hit point of its own,
        // so requiring `isHittable` here rejected every named form and sent the swipe to the
        // fallback — which on an iPad is the connection list behind the sheet.
        for identifier in ["theme-editor-form", "theme-workshop-list", "host-editor-form", "settings-form"] {
            let candidate = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
            if candidate.exists { return candidate }
        }
        return app.collectionViews.count > 0 ? app.collectionViews.element(boundBy: app.collectionViews.count - 1) : app
    }
}
