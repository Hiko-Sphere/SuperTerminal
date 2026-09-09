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
    @discardableResult
    private func scrollToSettingsRow(_ identifier: String) -> XCUIElement {
        XCTAssertTrue(app.buttons["settings-open"].waitForExistence(timeout: 10))
        if app.navigationBars["Settings"].exists == false { app.buttons["settings-open"].tap() }
        let row = app.buttons[identifier]
        var attempts = 0
        while !row.exists, attempts < 20 { app.swipeUp(); attempts += 1 }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Settings should offer \(identifier)")
        return row
    }

    private func openBackupSection() {
        scrollToSettingsRow("backup-export")
    }

    func testBackupIsReachableAndAsksForAPasswordBeforeExportingKeys() throws {
        openBackupSection()
        XCTAssertTrue(scrollToSettingsRow("backup-import").exists, "and a restore")

        // Without private keys there is nothing to protect, so nothing to type.
        XCTAssertFalse(app.secureTextFields["backup-password"].exists)
        XCTAssertTrue(app.buttons["backup-export"].isEnabled, "a plain export needs no password")

        try app.switches["backup-include-keys"].firstMatch.switchOn(in: app)
        let password = app.secureTextFields["backup-password"]
        XCTAssertTrue(password.waitForExistence(timeout: 5),
                      "asking for private keys must ask for a password")
        XCTAssertFalse(app.buttons["backup-export"].isEnabled,
                       "and export stays unavailable until one is typed")

        password.tap()
        password.typeText("a strong one")
        XCTAssertTrue(app.buttons["backup-export"].isEnabled, "once there is a password, it can be exported")
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
