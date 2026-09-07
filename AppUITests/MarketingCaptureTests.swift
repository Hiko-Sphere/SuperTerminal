import UIKit
import XCTest

/// Captures the App Store screenshots from the app as it actually runs.
///
/// Not a test of behaviour — a capture run. It drives the real interface to the states
/// the store listing shows, and attaches a full-screen image of each one. Everything in
/// those images is the app doing its real work: the sessions are real SSH sessions
/// against the OpenSSH servers `Marketing/AppStore/scripts/capture.sh` starts, every
/// fingerprint is the fingerprint of a key that server really presented, and every byte
/// of terminal output came back over the wire. Nothing is drawn, stubbed or replayed.
///
/// Skipped unless `ST_CAPTURE=1`, so an ordinary `xcodebuild test` never runs it.
///
/// The identities on screen are invented on purpose: the account is `deploy`, the
/// machines are `edge-01`, `db-primary` and `build-runner`, and their home directories
/// are seeded by the fixture image. No name, address or file belonging to the person
/// running the capture can reach a screenshot.
@MainActor
final class MarketingCaptureTests: XCTestCase {
    private nonisolated static var environment: [String: String] { ProcessInfo.processInfo.environment }
    private var environment: [String: String] { Self.environment }

    nonisolated override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(
            Self.environment["ST_CAPTURE"] == "1",
            "run Marketing/AppStore/scripts/capture.sh"
        )
        try XCTSkipUnless(
            Self.environment["ST_UITEST_SEED"] == "1",
            "the capture script provides the servers"
        )
    }

    /// The orientation this pass captures in. An iPad listing is landscape because that
    /// is how a terminal is used on one; a phone listing is portrait.
    private func applyOrientation() {
        XCUIDevice.shared.orientation =
            environment["ST_CAPTURE_ORIENTATION"] == "landscape" ? .landscapeLeft : .portrait
    }

    // MARK: - Launching

    /// Launches the app in the capture run's language, with the seeded connections.
    ///
    /// `trustingHostKeys` is the one thing a capture may switch off: the host-key sheet is
    /// itself one of the screenshots, and it cannot be photographed while the run is
    /// answering it automatically.
    private func launch(trustingHostKeys: Bool = true) -> XCUIApplication {
        applyOrientation()
        let app = XCUIApplication()
        let language = environment["ST_CAPTURE_LANGUAGE"] ?? "en-US"
        app.launchArguments += ["-AppleLanguages", "(\(language))", "-AppleLocale", language]
        for key in [
            "ST_UITEST_SEED", "ST_UITEST_HOST", "ST_UITEST_PORT", "ST_UITEST_USER",
            "ST_UITEST_KEY", "ST_UITEST_NAME", "ST_UITEST_HOSTS",
            "ST_UITEST_TERMINAL_THEME",
        ] {
            if let value = environment[key] { app.launchEnvironment[key] = value }
        }
        if trustingHostKeys { app.launchEnvironment["ST_UITEST_TRUST_HOST_KEYS"] = "1" }
        app.launch()
        return app
    }

    // MARK: - Capturing

    /// Attaches a full-screen image under a name the export script matches on.
    ///
    /// `XCUIScreen.main.screenshot()` rather than `app.screenshot()`: the status bar is
    /// part of what Apple's reviewers expect to see, and only the screen-level capture
    /// carries it.
    private func capture(_ name: String) {
        // Let anything still animating settle. A capture taken during a push transition
        // shows two screens sliding past each other, which is worse than a slow run.
        Thread.sleep(forTimeInterval: 1.2)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "stshot-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Reaching the terminal

    /// The terminal grid. Found by identifier, not by label: the label is translated and
    /// this run has to work in every language the app ships in.
    private func terminal(_ app: XCUIApplication) -> XCUIElement {
        app.otherElements.matching(identifier: "terminal-grid").firstMatch
    }

    /// Taps the saved connection with this name. Rows are identified by `host-row` and
    /// labelled "<name>, <detail>", so the name alone is enough and stays right in any
    /// language — the names are the fixture's, not the app's.
    private func openConnection(named name: String, in app: XCUIApplication) {
        let row = app.buttons.matching(
            NSPredicate(format: "identifier == %@ AND label BEGINSWITH %@", "host-row", name)
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the connection \(name) should be listed")
        row.tap()
    }

    private func waitUntilConnected(_ app: XCUIApplication, timeout: TimeInterval = 60) {
        XCTAssertTrue(terminal(app).waitForExistence(timeout: timeout), "the terminal should appear")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !app.activityIndicators.firstMatch.exists { return }
            usleep(200_000)
        }
        XCTFail("the session was still connecting after \(Int(timeout))s")
    }

    /// The terminal's accessibility value is the rendered screen, so it is also how a
    /// capture knows the remote command has finished and the picture is worth taking.
    @discardableResult
    private func waitForScreen(_ app: XCUIApplication, containing needle: String, timeout: TimeInterval = 45) -> String {
        let grid = terminal(app)
        let deadline = Date().addingTimeInterval(timeout)
        var latest = ""
        while Date() < deadline {
            latest = grid.value as? String ?? ""
            if latest.contains(needle) { return latest }
            usleep(200_000)
        }
        XCTFail("the remote host never printed \(needle). Screen was:\n\(latest)")
        return latest
    }

    /// Opens a connection and waits until its shell is answering.
    @discardableResult
    private func openTerminal(named name: String, in app: XCUIApplication) -> XCUIElement {
        openConnection(named: name, in: app)
        waitUntilConnected(app)
        let grid = terminal(app)
        // The shell's own first prompt, so nothing is typed into a session that has not
        // finished starting.
        waitForScreen(app, containing: "deploy@\(name)")
        // Tapping makes the capture independent of when the terminal claims the keyboard
        // rather than racing it, and the keyboard's arrival is what says typing will land.
        if grid.isHittable { grid.tap() }
        XCTAssertTrue(
            app.keyboards.element.waitForExistence(timeout: 15),
            "the keyboard should be up so the terminal can receive typing"
        )
        return grid
    }

    /// Types a command and waits for the prompt to come back with the marker on screen.
    private func run(_ command: String, awaiting marker: String, in app: XCUIApplication) {
        app.typeText(command + "\n")
        waitForScreen(app, containing: marker)
    }

    /// Goes back to the connection list on a stack layout; a no-op on the iPad split view,
    /// where the list is never covered.
    private func showList(_ app: XCUIApplication) {
        let row = app.buttons.matching(identifier: "host-row").firstMatch
        if row.exists, row.isHittable { return }
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists, back.isHittable { back.tap() }
        _ = row.waitForExistence(timeout: 10)
    }

    /// Puts the software keyboard away before a screenshot, where the platform offers a
    /// way to.
    ///
    /// The terminal holds the keyboard while it is on screen, which is right for using the
    /// app and wrong for photographing it: on an iPad in landscape it covers nearly half
    /// the grid. The iPad's keyboard has a key for exactly this. A phone's does not, and
    /// there the keyboard stays — with the accessory key row above it, which is what a
    /// phone in use actually looks like.
    ///
    /// The key carries no accessibility identifier, only a translated label, so it is
    /// found by label in the languages this run captures and otherwise by where it sits:
    /// the bottom-right corner of the keyboard. The positional fallback is confined to
    /// iPad, because the button in that corner of a phone keyboard is Return, and pressing
    /// it would run whatever is on the command line.
    private func dismissKeyboard(_ app: XCUIApplication) {
        guard app.keyboards.element.exists else { return }
        let keyboard = app.keyboards.element
        let labels = ["Hide keyboard", "隐藏键盘", "隱藏鍵盤"]
        var dismiss = app.keyboards.buttons.matching(
            NSPredicate(format: "identifier IN %@ OR label IN %@", labels, labels)
        ).firstMatch

        if !dismiss.exists, UIDevice.current.userInterfaceIdiom == .pad {
            let corner = keyboard.frame
            let candidates = app.keyboards.buttons.allElementsBoundByIndex.filter {
                $0.exists
                    && abs($0.frame.maxX - corner.maxX) < 12
                    && abs($0.frame.maxY - corner.maxY) < 12
            }
            if let bottomRight = candidates.first { dismiss = bottomRight }
        }

        guard dismiss.exists, dismiss.isHittable else { return }
        dismiss.tap()
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline, app.keyboards.element.exists { usleep(200_000) }
    }

    /// Scrolls the Settings form until `element` can be tapped.
    ///
    /// The Security section sits below the fold on a phone, and on an iPad the form is a
    /// sheet whose navigation bar overlaps rows that `isHittable` still calls hittable.
    private func scrollSettings(of app: XCUIApplication, to element: XCUIElement, attempts: Int = 15) -> Bool {
        let form = app.collectionViews["settings-form"].firstMatch
        let target = form.exists ? form : app.collectionViews.firstMatch
        for _ in 0 ..< attempts {
            if element.exists, element.isHittable { return true }
            target.swipeUp()
        }
        return element.exists && element.isHittable
    }

    // MARK: - The captures

    /// The host-key sheet, with the fingerprint of the key the server really presented.
    ///
    /// Runs first, and the capture script uninstalls the app before the run, so this is
    /// genuinely the first time this device has seen the server — which is the only state
    /// in which the app offers this sheet at all.
    func test00HostKeyPrompt() throws {
        let app = launch(trustingHostKeys: false)
        openConnection(named: "edge-01", in: app)
        let trust = app.buttons["prompt-trust"]
        XCTAssertTrue(trust.waitForExistence(timeout: 45), "the first connection should ask about the host key")
        // The sheet's own explanation of how to check the fingerprint on the server. It
        // is collapsed by default; opened, the screen shows the whole check rather than
        // half of it, and it is a real disclosure the user can open themselves.
        let howTo = app.descendants(matching: .any).matching(identifier: "prompt-howto").firstMatch
        if howTo.waitForExistence(timeout: 3), howTo.isHittable { howTo.tap() }
        capture("host-key")
        // Accepted, so the fingerprint is recorded and the rest of the run is not asked
        // again on this device.
        trust.tap()
        waitUntilConnected(app)
    }

    /// A live session: a real shell on a real server, with the key row that gives a phone
    /// the Escape, Tab and Control it does not otherwise have.
    func test01Terminal() throws {
        let app = launch()
        openTerminal(named: "edge-01", in: app)
        run("cd services/api", awaiting: "api$", in: app)
        run("ls -la", awaiting: "Makefile", in: app)
        run("git status -sb", awaiting: "metrics.go", in: app)
        run("git log --oneline -3", awaiting: "initial service", in: app)
        run("cat config/api.yaml", awaiting: "workers", in: app)
        run("wc -l src/*.go", awaiting: "total", in: app)
        run("df -h /", awaiting: "Filesystem", in: app)
        run("uptime", awaiting: "load average", in: app)
        dismissKeyboard(app)
        capture("terminal")
    }

    /// Several machines open at once, all of them real sessions.
    func test02Sessions() throws {
        let app = launch()
        openTerminal(named: "edge-01", in: app)
        run("uptime", awaiting: "load average", in: app)
        showList(app)
        openTerminal(named: "db-primary", in: app)
        run("df -h /", awaiting: "Filesystem", in: app)
        showList(app)
        openTerminal(named: "build-runner", in: app)
        run("uname -srm", awaiting: "Linux", in: app)
        run("ls -la services", awaiting: "web", in: app)
        run("git -C services/api log --oneline -3", awaiting: "initial service", in: app)
        showList(app)
        // On a phone the list is now the whole screen and there is no keyboard to put
        // away; on an iPad the sidebar sits beside the terminal, and the keyboard would
        // otherwise cover the half of the screen this shot is about.
        dismissKeyboard(app)
        capture("sessions")
    }

    /// Keys generated on the device, listed with the fingerprints they really have.
    func test03Keys() throws {
        let app = launch()
        app.buttons["settings-open"].tap()
        let keys = app.descendants(matching: .any).matching(identifier: "settings-keys").firstMatch
        XCTAssertTrue(scrollSettings(of: app, to: keys), "Settings should offer the Keys screen")
        keys.tap()

        // Names typed into a field that capitalises words, so nothing with an internal
        // capital: "iPad" would be typed back as "IPad" and photographed that way.
        // Both algorithms the app offers, so the list shows the real choice rather than
        // one row twice. The names are not localized, so this works in every language.
        generateKey(named: "Personal", algorithm: nil, in: app, capturing: "key-created")
        generateKey(named: "Ops runner", algorithm: "ECDSA P-256", in: app, capturing: nil)

        let fingerprints = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "SHA256:")
        )
        XCTAssertTrue(fingerprints.firstMatch.waitForExistence(timeout: 10), "the keys should be listed")
        XCTAssertGreaterThanOrEqual(fingerprints.count, 2, "both generated keys should be listed")
        capture("keys")
    }

    /// Generates one key through the interface the user uses, optionally photographing the
    /// screen that shows the public half.
    private func generateKey(
        named name: String,
        algorithm: String?,
        in app: XCUIApplication,
        capturing shot: String?
    ) {
        let add = app.buttons["add-key"]
        XCTAssertTrue(add.waitForExistence(timeout: 15), "the Keys screen should offer Add key")
        // The previous sheet's dismissal animation still owns the screen for a moment, and
        // a tap that lands then opens nothing at all.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !add.isHittable { usleep(200_000) }
        add.tap()

        let generate = app.buttons["generate-key"]
        XCTAssertTrue(generate.waitForExistence(timeout: 10), "the menu should offer Generate")
        generate.tap()

        let field = app.textFields["key-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the sheet should ask for a name")
        field.tap()
        field.typeText(name)

        if let algorithm {
            // The algorithm names are not localized, so the option can be found by label
            // whatever language the run is in.
            let picker = app.buttons.matching(
                NSPredicate(format: "label CONTAINS %@", "Ed25519")
            ).firstMatch
            if picker.waitForExistence(timeout: 5), picker.isHittable {
                picker.tap()
                let option = app.buttons[algorithm]
                if option.waitForExistence(timeout: 5), option.isHittable { option.tap() }
            }
        }

        app.buttons["key-generate"].tap()
        let done = app.buttons["key-dismiss"]
        XCTAssertTrue(done.waitForExistence(timeout: 20), "generating should land on the new key")
        // The public half, which is what the user copies to the server.
        if let shot { capture(shot) }
        done.tap()
    }

    /// A full-screen editor over the real PTY: alternate screen, syntax colour, a cursor
    /// the remote program is placing.
    func test04Vim() throws {
        let app = launch()
        openTerminal(named: "edge-01", in: app)
        run("cd services/api", awaiting: "api$", in: app)
        app.typeText("vim src/server.go\n")
        waitForScreen(app, containing: "type Server struct")
        dismissKeyboard(app)
        capture("vim")
        // Leave the alternate screen so the session is not left inside an editor.
        app.typeText(":q!\n")
    }

    /// A curses program with meters and a live process table.
    func test05Htop() throws {
        let app = launch()
        openTerminal(named: "edge-01", in: app)
        app.typeText("htop -d 20\n")
        waitForScreen(app, containing: "Mem")
        dismissKeyboard(app)
        capture("htop")
        app.typeText("q")
    }

    /// The command palette, ranking real connections and real open sessions.
    func test06Palette() throws {
        let app = launch()
        openTerminal(named: "edge-01", in: app)
        run("uptime", awaiting: "load average", in: app)
        app.buttons["terminal-menu"].tap()
        let palette = app.buttons["terminal-menu-palette"]
        XCTAssertTrue(palette.waitForExistence(timeout: 10))
        palette.tap()
        let query = app.textFields["palette-query"]
        XCTAssertTrue(query.waitForExistence(timeout: 10), "the palette should open")
        query.typeText("dpr")
        // `dpr` matches `db-primary` only if the ranking is really fuzzy; a substring
        // filter would show nothing, which is what makes this worth photographing.
        XCTAssertTrue(
            app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "palette-")
            ).firstMatch.waitForExistence(timeout: 10),
            "the palette should rank something for a fuzzy query"
        )
        capture("palette")
    }

    /// Searching the scrollback of a live session.
    func test07Find() throws {
        let app = launch()
        openTerminal(named: "edge-01", in: app)
        run("cd services/api", awaiting: "api$", in: app)
        run("git log --oneline", awaiting: "initial service", in: app)
        run("cat ../../notes.md", awaiting: "worker pool", in: app)
        app.buttons["terminal-menu"].tap()
        let find = app.buttons["terminal-menu-find"]
        XCTAssertTrue(find.waitForExistence(timeout: 10))
        find.tap()
        let query = app.textFields["find-query"]
        XCTAssertTrue(query.waitForExistence(timeout: 10), "the find bar should open")
        query.tap()
        query.typeText("queue")
        dismissKeyboard(app)
        capture("find")
    }

    /// The connection editor, with the fields the app really offers.
    func test08Editor() throws {
        let app = launch()
        let row = app.buttons.matching(
            NSPredicate(format: "identifier == %@ AND label BEGINSWITH %@", "host-row", "db-primary")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.press(forDuration: 1.2)
        let edit = app.buttons["host-edit"]
        if edit.waitForExistence(timeout: 5), edit.isHittable {
            edit.tap()
            XCTAssertTrue(app.textFields["hostname"].waitForExistence(timeout: 10), "the editor should open")
            capture("editor")
        }
    }
}
