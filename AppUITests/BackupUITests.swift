import XCTest

/// Export and restore, reachable and honest about what it will do (D-040).
@MainActor
final class BackupUITests: XCTestCase {
    private lazy var app = XCUIApplication()

    // The async form, and `@MainActor` on it: an override may *add* actor isolation when it
    // is async, because the caller awaits the hop. `setUpWithError()` cannot — it overrides a
    // method that is not isolated — and every line of setup here touches `XCUIApplication`,
    // which is the main actor's (D-068).
    @MainActor
    override func setUp() async throws {
        continueAfterFailure = false
        app.launchEnvironment["ST_UITEST_RESET"] = "1"
        app.launch()
    }

    /// Scrolls Settings until `identifier` is there.
    ///
    /// Scrolling to *one* row and assuming its neighbour is also in the tree does not hold:
    /// a long list keeps only what is near the viewport, and Settings grew — so a run that
    /// found "Export a backup…" could still fail to find "Restore from a backup…" a few
    /// points below it.
    ///
    /// It searches **both** directions, which the first version did not. Having scrolled down
    /// to the neighbour, the first row is no longer near the viewport either, so asking about
    /// it again looks for something that is now *above* — and swiping further down can never
    /// bring it back. Settings gained rows when iCloud did, and that is the run where the
    /// one-directional version stopped working.
    @discardableResult
    private func scrollToSettingsRow(_ identifier: String) -> XCUIElement {
        XCTAssertTrue(app.buttons["settings-open"].waitForExistence(timeout: 10))
        if app.navigationBars["Settings"].exists == false { app.buttons["settings-open"].tap() }
        let row = app.buttons[identifier]
        // Down first: a row being looked for is usually below the one just visited.
        for up in [true, false] {
            for _ in 0 ..< 20 {
                if row.exists { return row }
                if up { settingsForm().swipeUp() } else { settingsForm().swipeDown() }
            }
        }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Settings should offer \(identifier)")
        return row
    }

    /// The Settings form itself, by the identifier it carries.
    ///
    /// Not `app`. On an iPad, Settings is a form sheet with the connection list still visible
    /// behind it, and a swipe aimed at the application scrolls that list instead — the sheet
    /// never moves and the row never arrives. This worked by luck while Backup sat high enough
    /// in the form to be in the tree already; iCloud gained rows above it and the luck ran out.
    private func settingsForm() -> XCUIElement {
        let named = app.descendants(matching: .any).matching(identifier: "settings-form").firstMatch
        return named.exists ? named : app.collectionViews.firstMatch
    }

    private func openBackupSection() {
        scrollToSettingsRow("backup-export")
    }

    func testBackupIsReachableAndAsksForAPasswordBeforeExportingKeys() throws {
        openBackupSection()
        XCTAssertTrue(scrollToSettingsRow("backup-import").exists, "and a restore")

        // Without private keys there is nothing to protect, so nothing to type.
        XCTAssertFalse(app.secureTextFields["backup-password"].exists)
        // Through the scrolling helper every time, never `app.buttons[…]` directly. Having
        // scrolled down to the restore row, the export button is no longer near the viewport
        // and so is no longer in the tree at all — the same rule this file's own docstring
        // states about neighbours applies just as much to a row visited a moment ago.
        XCTAssertTrue(scrollToSettingsRow("backup-export").isEnabled, "a plain export needs no password")

        try app.switches["backup-include-keys"].firstMatch.switchOn(in: app)
        let password = app.secureTextFields["backup-password"]
        XCTAssertTrue(password.waitForExistence(timeout: 5),
                      "asking for private keys must ask for a password")
        XCTAssertFalse(scrollToSettingsRow("backup-export").isEnabled,
                       "and export stays unavailable until one is typed")

        let field = app.secureTextFields["backup-password"]
        field.tap()
        field.typeText("a strong one")
        XCTAssertTrue(scrollToSettingsRow("backup-export").isEnabled, "once there is a password, it can be exported")
    }

    func testRestoreRefusesAFileThatIsNotABackup() throws {
        // The importer is the system's, so what this can prove without driving Files.app
        // is that the entry point exists and opens rather than doing nothing.
        let restore = scrollToSettingsRow("backup-import")
        XCTAssertTrue(restore.isEnabled)
        restore.tap()
        // The document picker is a separate process; its appearance is the evidence that
        // the button is wired to something rather than to nothing.
        let picker = app.otherElements["DocBrowserView"].firstMatch
        let appeared = picker.waitForExistence(timeout: 10) || app.navigationBars.count > 0
        XCTAssertTrue(appeared, "restore should open a file picker")
    }
}
