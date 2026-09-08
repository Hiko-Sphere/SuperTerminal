import XCTest

/// Browsing a real server's files from the interface (D-042).
///
/// The harness runs a real OpenSSH server with the SFTP subsystem enabled, so this is the
/// whole path: a connection row, an SSH handshake, a subsystem channel, a listing.
@MainActor
final class FileBrowserUITests: XCTestCase {
    private lazy var app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        for key in ["ST_UITEST_SEED", "ST_UITEST_HOST", "ST_UITEST_PORT", "ST_UITEST_USER",
                    "ST_UITEST_KEY", "ST_UITEST_TRUST_HOST_KEYS", "ST_UITEST_NAME"] {
            if let value = environment[key] { app.launchEnvironment[key] = value }
        }
        try XCTSkipUnless(environment["ST_UITEST_SEED"] == "1", "needs the seeded connection")
        app.launch()
    }

    func testBrowsingARealServerListsItsFiles() throws {
        let row = app.buttons.matching(identifier: "host-row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        for _ in 0 ..< 20 where !row.isHittable { usleep(150_000) }
        row.press(forDuration: 1.0)

        let browse = app.buttons["host-files"].firstMatch
        XCTAssertTrue(browse.waitForExistence(timeout: 5), "a connection offers to browse its files")
        browse.tap()

        // The listing is the evidence: it comes from a real sshd's own sftp subsystem,
        // over a real handshake, and nothing in the app can invent it.
        // By descendants rather than otherElements: the path bar is a scroll view, and
        // which element class SwiftUI gives it is not a promise worth depending on.
        let path = app.descendants(matching: .any).matching(identifier: "files-path").firstMatch
        XCTAssertTrue(path.waitForExistence(timeout: 30), "the browser should reach a directory")
        let anyRow = app.buttons.matching(identifier: "file-row").firstMatch
        let listed = anyRow.waitForExistence(timeout: 20)
        let emptyFolder = app.staticTexts["This folder is empty"].exists
        XCTAssertTrue(listed || emptyFolder, "a real listing, even if the home directory happens to be empty")

        // The actions a file manager has to offer are present and reachable.
        XCTAssertTrue(app.buttons["files-menu"].exists)
        app.buttons["files-menu"].tap()
        XCTAssertTrue(app.buttons["New Folder"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Upload…"].exists)
        XCTAssertTrue(app.buttons["Transfers"].exists)
    }

    func testPermissionsAreEditableOnARealFile() throws {
        let row = app.buttons.matching(identifier: "host-row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        for _ in 0 ..< 20 where !row.isHittable { usleep(150_000) }
        row.press(forDuration: 1.0)
        let browse = app.buttons["host-files"].firstMatch
        XCTAssertTrue(browse.waitForExistence(timeout: 5))
        browse.tap()

        let path = app.descendants(matching: .any).matching(identifier: "files-path").firstMatch
        XCTAssertTrue(path.waitForExistence(timeout: 30))
        let entry = app.buttons.matching(identifier: "file-row").firstMatch
        guard entry.waitForExistence(timeout: 20) else {
            throw XCTSkip("the home directory is empty, so there is nothing to inspect")
        }

        entry.press(forDuration: 1.0)
        let permissions = app.buttons["Permissions…"].firstMatch
        XCTAssertTrue(permissions.waitForExistence(timeout: 5), "a row offers to edit its mode")
        permissions.tap()

        // Both ways in are present: the octal for people who think in chmod, and the
        // symbolic string a listing shows for people who do not.
        let octal = app.textFields["permissions-octal"]
        XCTAssertTrue(octal.waitForExistence(timeout: 5))
        let shown = (octal.value as? String) ?? ""
        XCTAssertFalse(shown.isEmpty, "the file's real mode is filled in, not a default")
        XCTAssertTrue(app.buttons["permissions-apply"].exists)
        app.buttons["Cancel"].firstMatch.tap()
    }
}
