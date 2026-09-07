import XCTest

/// TEMPORARY probe: does the snippet picker's search field exist and filter?
@MainActor
final class ZZSearchProbeUITests: XCTestCase {
    private lazy var app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchEnvironment["ST_UITEST_SEED"] = "1"
        app.launchEnvironment["ST_UITEST_HOST"] = "127.0.0.1"
        app.launchEnvironment["ST_UITEST_PORT"] = "9"
        app.launchEnvironment["ST_UITEST_USER"] = "probe"
        app.launchEnvironment["ST_UITEST_KEY"] = "-----BEGIN OPENSSH PRIVATE KEY-----\nprobe\n-----END OPENSSH PRIVATE KEY-----\n"
        app.launchEnvironment["ST_UITEST_TRUST_HOST_KEYS"] = "1"
        app.launchEnvironment["ST_UITEST_NAME"] = "Probe Server"
        app.launch()
    }

    private func openSnippetPicker() {
        let row = app.buttons.matching(identifier: "host-row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "seeded connection should be listed")
        row.tap()
        let session = app.buttons["Session"]
        XCTAssertTrue(session.waitForExistence(timeout: 20), "the Session menu should exist")
        session.tap()
        let snippets = app.buttons["Snippets…"]
        XCTAssertTrue(snippets.waitForExistence(timeout: 10), "the menu should offer snippets")
        snippets.tap()
    }

    func testSearchFieldExistsAndFiltersSnippets() throws {
        openSnippetPicker()

        let starter = app.buttons["Add a starter set"]
        XCTAssertTrue(starter.waitForExistence(timeout: 10), "empty state should offer the starter set")
        starter.tap()

        let disk = app.buttons["snippet-Disk usage"]
        let memory = app.buttons["snippet-Memory"]
        XCTAssertTrue(disk.waitForExistence(timeout: 10), "Disk usage should be listed")
        XCTAssertTrue(memory.exists, "Memory should be listed")

        // THE CLAIM: a search field in the picker.
        let field = app.searchFields.firstMatch
        XCTAssertTrue(
            field.waitForExistence(timeout: 10),
            "a search field should exist in the picker; other elements: "
                + app.descendants(matching: .any).allElementsBoundByIndex.prefix(40)
                    .map { "\($0.elementType.rawValue):\($0.identifier):\($0.label)" }.joined(separator: " | ")
        )
        field.tap()
        field.typeText("memory")

        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: disk, handler: nil)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(memory.exists, "the matching snippet should survive the filter")
    }

    func testTheQueryLeaksAcrossTheScopeSwitch() throws {
        openSnippetPicker()
        let starter = app.buttons["Add a starter set"]
        if starter.waitForExistence(timeout: 10) { starter.tap() }

        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "a search field should exist")
        field.tap()
        field.typeText("memory")

        app.segmentedControls.buttons["History"].tap()
        // If the query is carried over, the History list opens pre-filtered by a query
        // the user typed for snippets.
        XCTAssertEqual(
            field.value as? String, "memory",
            "the snippet query should not still be filtering History"
        )
    }
}
