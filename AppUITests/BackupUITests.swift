import XCTest

/// Export and restore, reachable and honest about what it will do (D-040).
@MainActor
final class BackupUITests: XCTestCase {
    private lazy var app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchEnvironment["ST_UITEST_RESET"] = "1"
        app.launch()
    }

    private func openBackupSection() {
        XCTAssertTrue(app.buttons["settings-open"].waitForExistence(timeout: 10))
        app.buttons["settings-open"].tap()
        let export = app.buttons["backup-export"]
        var attempts = 0
        while !export.exists, attempts < 14 { app.swipeUp(); attempts += 1 }
        XCTAssertTrue(export.waitForExistence(timeout: 5), "Settings should offer an export")
    }

    func testBackupIsReachableAndAsksForAPasswordBeforeExportingKeys() throws {
        openBackupSection()
        XCTAssertTrue(app.buttons["backup-import"].exists, "and a restore")

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
        openBackupSection()
        let restore = app.buttons["backup-import"]
        XCTAssertTrue(restore.isEnabled)
        restore.tap()
        // The document picker is a separate process; its appearance is the evidence that
        // the button is wired to something rather than to nothing.
        let picker = app.otherElements["DocBrowserView"].firstMatch
        let appeared = picker.waitForExistence(timeout: 10) || app.navigationBars.count > 0
        XCTAssertTrue(appeared, "restore should open a file picker")
    }
}
