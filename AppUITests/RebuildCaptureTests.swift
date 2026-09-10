import UIKit
import XCTest

/// The 2026-09 store capture: eight screens, photographed from the app as it really runs.
///
/// A capture run, not a test of behaviour. It drives the real interface to the eight states
/// in `Marketing/Rebuild-2026-09-10/app-store/SCREENSHOT_PLAN.md` and attaches a
/// full-screen image of each. Everything in those images is the app doing its actual work:
/// the sessions are real SSH sessions against the container
/// `Marketing/Rebuild-2026-09-10/automation/fixture` starts, the file listing is a real
/// SFTP listing, the forward really carries bytes, the tmux panes are a real tmux server's,
/// and the desktop is a real X session decoded from real RFB. Nothing is drawn or replayed.
///
/// Separate from `MarketingCaptureTests` on purpose: that class still produces the earlier
/// six-screen set, and neither run should be able to break the other. Skipped unless
/// `ST_REBUILD_CAPTURE=1`, so an ordinary `xcodebuild test` never runs either of them.
///
/// The identities on screen are invented: the account is `deploy`, the machines are
/// `edge-01`, `db-primary` and `build-runner`, their addresses are under `*.localhost`
/// (reserved by RFC 6761), and every file in the home directory was written for this
/// purpose. Nothing belonging to the person running the capture can reach an image.
@MainActor
final class RebuildCaptureTests: XCTestCase {
    private nonisolated static var environment: [String: String] { ProcessInfo.processInfo.environment }
    private var environment: [String: String] { Self.environment }

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    nonisolated override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(
            Self.environment["ST_REBUILD_CAPTURE"] == "1",
            "run Marketing/Rebuild-2026-09-10/automation/capture.sh"
        )
        try XCTSkipUnless(
            Self.environment["ST_UITEST_SEED"] == "1",
            "the capture script provides the servers"
        )
    }

    // MARK: - Launching

    private func applyOrientation() {
        XCUIDevice.shared.orientation =
            environment["ST_CAPTURE_ORIENTATION"] == "landscape" ? .landscapeLeft : .portrait
    }

    private func launch() -> XCUIApplication {
        applyOrientation()
        let app = XCUIApplication()
        let language = environment["ST_CAPTURE_LANGUAGE"] ?? "en-US"
        app.launchArguments += ["-AppleLanguages", "(\(language))", "-AppleLocale", language]
        for key in [
            "ST_UITEST_SEED", "ST_UITEST_HOST", "ST_UITEST_PORT", "ST_UITEST_USER",
            "ST_UITEST_KEY", "ST_UITEST_NAME", "ST_UITEST_HOSTS",
            "ST_UITEST_TERMINAL_THEME", "ST_UITEST_VNC_PORT", "ST_UITEST_FORWARD_PORT",
            "ST_UITEST_TMUX_PORT", "ST_UITEST_TMUX_USER", "ST_UITEST_TMUX_PASSWORD",
            "ST_UITEST_TMUX_HOST", "ST_UITEST_TMUX_NAME", "ST_UITEST_SCREEN_NAME",
            "ST_UITEST_FORWARD_NAME", "ST_UITEST_TUNNEL_NAME",
        ] {
            if let value = environment[key] { app.launchEnvironment[key] = value }
        }
        // Every capture but the host-key sheet wants to be past that prompt, and this set
        // has no host-key screen in it — the fingerprint story is told in the copy.
        app.launchEnvironment["ST_UITEST_TRUST_HOST_KEYS"] = "1"
        app.launch()
        return app
    }

    // MARK: - Capturing

    private func capture(_ name: String) {
        // Let anything still animating settle. A capture taken during a push transition
        // shows two screens sliding past each other.
        Thread.sleep(forTimeInterval: 1.4)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "stshot-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Reaching things

    private func terminal(_ app: XCUIApplication) -> XCUIElement {
        app.otherElements.matching(identifier: "terminal-grid").firstMatch
    }

    private func row(_ identifier: String, startingWith name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "identifier == %@ AND label BEGINSWITH %@", identifier, name)
        ).firstMatch
    }

    private func openConnection(named name: String, in app: XCUIApplication) {
        let host = row("host-row", startingWith: name, in: app)
        XCTAssertTrue(host.waitForExistence(timeout: 25), "the connection \(name) should be listed")
        host.tap()
    }

    /// The screen a connection lands on. A plain session draws `terminal-grid`; a tmux
    /// connection draws tmux's own arrangement instead, so either counts as arrival.
    private func sessionArrived(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if terminal(app).exists || app.buttons["tmux-menu"].exists { return true }
            usleep(300_000)
        }
        return false
    }

    private func waitUntilConnected(_ app: XCUIApplication, timeout: TimeInterval = 60) {
        XCTAssertTrue(sessionArrived(app, timeout: timeout), "the session should appear")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !app.activityIndicators.firstMatch.exists { return }
            usleep(200_000)
        }
        XCTFail("the session was still connecting after \(Int(timeout))s")
    }

    /// The terminal's accessibility value is the rendered grid, so it is how a capture
    /// knows the remote command has finished and the picture is worth taking.
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

    @discardableResult
    private func openTerminal(named name: String, in app: XCUIApplication) -> XCUIElement {
        openConnection(named: name, in: app)
        waitUntilConnected(app)
        let grid = terminal(app)
        waitForScreen(app, containing: "deploy@\(name)")
        if grid.isHittable { grid.tap() }
        XCTAssertTrue(
            app.keyboards.element.waitForExistence(timeout: 15),
            "the keyboard should be up so the terminal can receive typing"
        )
        return grid
    }

    private func run(_ command: String, awaiting marker: String, in app: XCUIApplication) {
        app.typeText(command + "\n")
        waitForScreen(app, containing: marker)
    }

    /// Goes back to the connection list on a stack layout; a no-op on the iPad split view.
    private func showList(_ app: XCUIApplication) {
        let host = app.buttons.matching(identifier: "host-row").firstMatch
        if host.exists, host.isHittable { return }
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists, back.isHittable { back.tap() }
        _ = host.waitForExistence(timeout: 12)
    }

    /// Puts the software keyboard away, using the key the keyboard itself provides.
    private func dismissKeyboard(_ app: XCUIApplication) {
        guard app.keyboards.element.exists else { return }
        let keyboard = app.keyboards.element
        let labels = ["Hide keyboard", "隐藏键盘", "隱藏鍵盤"]
        var dismiss = app.keyboards.buttons.matching(
            NSPredicate(format: "identifier IN %@ OR label IN %@", labels, labels)
        ).firstMatch
        if !dismiss.exists, isPad {
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

    /// Waits until the remote desktop is actually showing a picture.
    ///
    /// The view exists as soon as the screen is opened, so its presence proves nothing —
    /// a capture taken then is a black rectangle with a spinner on it. What says the
    /// framebuffer has arrived is the connecting indicator going away.
    @discardableResult
    private func waitForDesktop(_ app: XCUIApplication, timeout: TimeInterval = 90) -> Bool {
        let desktop = app.descendants(matching: .any).matching(identifier: "vnc-screen").firstMatch
        guard desktop.waitForExistence(timeout: timeout) else { return false }
        let connecting = app.descendants(matching: .any).matching(identifier: "vnc-connecting").firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, connecting.exists { usleep(300_000) }
        // One more beat for the first incremental updates to land on top of the first frame.
        Thread.sleep(forTimeInterval: 3)
        return !connecting.exists
    }

    private func openContextMenu(onHost name: String, in app: XCUIApplication) {
        let host = row("host-row", startingWith: name, in: app)
        XCTAssertTrue(host.waitForExistence(timeout: 25), "the connection \(name) should be listed")
        host.press(forDuration: 1.2)
    }

    private func tapMenuItem(_ identifier: String, in app: XCUIApplication, timeout: TimeInterval = 8) -> Bool {
        let item = app.buttons[identifier]
        guard item.waitForExistence(timeout: timeout), item.isHittable else { return false }
        item.tap()
        return true
    }

    // MARK: - 01 · A real terminal

    func test01Terminal() throws {
        let app = launch()
        openTerminal(named: "edge-01", in: app)
        run("cd services/api", awaiting: "api$", in: app)
        run("ls -la", awaiting: "Makefile", in: app)
        run("git status -sb", awaiting: "metrics.go", in: app)
        run("git log --oneline -3", awaiting: "initial service", in: app)
        run("cat config/api.yaml", awaiting: "workers", in: app)
        run("uptime", awaiting: "load average", in: app)
        capture("01-terminal")
    }

    // MARK: - 02 · One connection, everything on it

    /// The differentiator: a shell, a file browser, a forward and a desktop, all on one
    /// server and therefore on one pooled SSH transport. The proof is the connection list
    /// with four sections populated at once.
    func test02OneConnection() throws {
        let app = launch()

        // A shell.
        openTerminal(named: "edge-01", in: app)
        run("uptime", awaiting: "load average", in: app)
        dismissKeyboard(app)

        // A forward, started from the session's own menu, carrying real bytes.
        if tapMenuItem("terminal-menu", in: app) || app.buttons["terminal-menu"].exists {
            app.buttons["terminal-menu"].tap()
        }
        if tapMenuItem("terminal-menu-forwards", in: app) {
            let start = app.buttons["start-port-forward"].firstMatch
            if start.waitForExistence(timeout: 8), start.isHittable { start.tap() }
            Thread.sleep(forTimeInterval: 2)
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }

        showList(app)

        // A file browser on the same server.
        openContextMenu(onHost: "edge-01", in: app)
        _ = tapMenuItem("host-files", in: app)
        XCTAssertTrue(
            app.buttons.matching(identifier: "file-row").firstMatch.waitForExistence(timeout: 40),
            "the file browser should list the server's files"
        )
        showList(app)

        // A desktop on the same server, through the same connection.
        let screen = app.buttons.matching(identifier: "screen-row").firstMatch
        if screen.waitForExistence(timeout: 10), screen.isHittable {
            screen.tap()
            // Wait for the picture, not merely for the row: a list captured while the
            // screen is still negotiating shows "Starting screen sharing", which is a
            // photograph of a connection that has not happened yet.
            _ = waitForDesktop(app)
            showList(app)
        }

        capture("02-one-connection")
    }

    // MARK: - 03 · Panes (iPad) / several sessions (iPhone)

    /// Deliberately a different subject per device rather than the same picture scaled:
    /// split panes are an iPad affordance, and a phone's story is fast switching.
    func test03Panes() throws {
        let app = launch()

        if isPad {
            openTerminal(named: "edge-01", in: app)
            run("tail -f logs/health.log", awaiting: "ok", in: app)
            dismissKeyboard(app)
            app.buttons["terminal-menu"].tap()
            guard tapMenuItem("terminal-menu-split-right", in: app) else {
                XCTFail("the session menu should offer a split"); return
            }
            // The split asks what to put in the new pane.
            let picker = app.otherElements["split-target-picker"]
            if picker.waitForExistence(timeout: 8) {
                let target = row("host-row", startingWith: "db-primary", in: app)
                if target.waitForExistence(timeout: 8), target.isHittable {
                    target.tap()
                } else {
                    app.buttons.matching(identifier: "host-row").firstMatch.tap()
                }
            }
            // Two panes, both live.
            let panes = app.otherElements.matching(identifier: "terminal-grid")
            let deadline = Date().addingTimeInterval(45)
            while Date() < deadline, panes.count < 2 { usleep(300_000) }
            XCTAssertGreaterThanOrEqual(panes.count, 2, "the split should produce a second pane")
            dismissKeyboard(app)
        } else {
            for name in ["edge-01", "db-primary", "build-runner"] {
                openTerminal(named: name, in: app)
                run("uptime", awaiting: "load average", in: app)
                dismissKeyboard(app)
                showList(app)
            }
        }

        capture("03-panes")
    }

    // MARK: - 04 · The server's files

    func test04Files() throws {
        let app = launch()
        openContextMenu(onHost: "edge-01", in: app)
        guard tapMenuItem("host-files", in: app) else {
            XCTFail("the connection's menu should offer Browse Files"); return
        }
        XCTAssertTrue(
            app.buttons.matching(identifier: "file-row").firstMatch.waitForExistence(timeout: 45),
            "the file browser should list the server's files"
        )
        // Into the project directory, so the listing is a real working tree rather than a
        // home directory with four entries.
        let services = row("file-row", startingWith: "services", in: app)
        if services.waitForExistence(timeout: 8), services.isHittable {
            services.tap()
            let api = row("file-row", startingWith: "api", in: app)
            if api.waitForExistence(timeout: 12), api.isHittable { api.tap() }
        }
        _ = app.buttons.matching(identifier: "file-row").firstMatch.waitForExistence(timeout: 20)
        capture("04-files")
    }

    // MARK: - 05 · Forwards, with live counters

    func test05Forwards() throws {
        let app = launch()
        openTerminal(named: "edge-01", in: app)
        dismissKeyboard(app)
        app.buttons["terminal-menu"].tap()
        guard tapMenuItem("terminal-menu-forwards", in: app) else {
            XCTFail("the session menu should offer Port Forwards"); return
        }
        let rule = app.buttons.matching(identifier: "port-forward-row").firstMatch
        XCTAssertTrue(rule.waitForExistence(timeout: 20), "the seeded forward should be listed")
        let start = app.buttons["start-port-forward"].firstMatch
        if start.waitForExistence(timeout: 8), start.isHittable { start.tap() }
        Thread.sleep(forTimeInterval: 3)

        // Put real traffic through it. The harness seeds a second connection whose address
        // is the forward's own listening port on this device, so opening it is a genuine
        // SSH session carried by the tunnel — which is what makes the counters on the
        // forwards screen real numbers rather than zeroes.
        if let viaName = environment["ST_UITEST_TUNNEL_NAME"] {
            let done = app.navigationBars.buttons.matching(
                NSPredicate(format: "label IN %@", ["Done", "完成"])
            ).firstMatch
            if done.exists, done.isHittable { done.tap() }
            showList(app)
            let via = row("host-row", startingWith: viaName, in: app)
            if via.waitForExistence(timeout: 12), via.isHittable {
                via.tap()
                if sessionArrived(app, timeout: 60) {
                    waitForScreen(app, containing: "deploy@", timeout: 45)
                    dismissKeyboard(app)
                }
            }
            // Back to the forwards screen, now with the traffic counted. Returned to
            // through the "Open sessions" row rather than the connection row: tapping the
            // connection opens a *second* session, and a forward belongs to the session it
            // was started from — the new one would show the rule stopped.
            showList(app)
            let session = row("open-session", startingWith: "edge-01", in: app)
            if session.waitForExistence(timeout: 12), session.isHittable {
                session.tap()
            } else {
                openConnection(named: "edge-01", in: app)
            }
            waitUntilConnected(app)
            dismissKeyboard(app)
            app.buttons["terminal-menu"].tap()
            _ = tapMenuItem("terminal-menu-forwards", in: app)
            _ = app.buttons.matching(identifier: "port-forward-row").firstMatch.waitForExistence(timeout: 15)
            Thread.sleep(forTimeInterval: 2)
        }
        capture("05-forwards")
    }

    // MARK: - 06 · tmux

    func test06Tmux() throws {
        let app = launch()
        let name = environment["ST_UITEST_TMUX_NAME"] ?? "tmux Test Server"
        openConnection(named: name, in: app)
        XCTAssertTrue(sessionArrived(app, timeout: 90), "the tmux connection should attach")
        // tmux draws its own arrangement; the toolbar it brings is the tell.
        XCTAssertTrue(
            app.buttons["tmux-menu"].waitForExistence(timeout: 60),
            "attaching should put tmux's own toolbar on screen"
        )
        let pane = app.otherElements.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "tmux-pane-")
        ).firstMatch
        if pane.waitForExistence(timeout: 20), pane.isHittable { pane.tap() }
        if app.keyboards.element.waitForExistence(timeout: 10) {
            app.typeText("uptime\n")
            Thread.sleep(forTimeInterval: 2)
            dismissKeyboard(app)
        }
        // A second pane, made by tmux rather than by the app's own splitter.
        app.buttons["tmux-menu"].tap()
        if tapMenuItem("tmux-split-right", in: app) {
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline,
                  app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tmux-pane-")).count < 2 {
                usleep(300_000)
            }
            dismissKeyboard(app)
        }
        capture("06-tmux")
    }

    // MARK: - 07 · A key that cannot leave

    func test07Security() throws {
        let app = launch()
        app.buttons["settings-open"].tap()
        let keys = app.descendants(matching: .any).matching(identifier: "settings-keys").firstMatch
        XCTAssertTrue(scrollSettings(of: app, to: keys), "Settings should offer the Keys screen")
        keys.tap()

        generateKey(named: "Personal", inEnclave: false, in: app)
        generateKey(named: "On call", inEnclave: true, in: app)

        let fingerprints = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "SHA256:")
        )
        XCTAssertTrue(fingerprints.firstMatch.waitForExistence(timeout: 12), "the keys should be listed")
        XCTAssertGreaterThanOrEqual(fingerprints.count, 2, "both keys should be listed")
        capture("07-security")
    }

    private func generateKey(named name: String, inEnclave: Bool, in app: XCUIApplication) {
        let add = app.buttons["add-key"]
        XCTAssertTrue(add.waitForExistence(timeout: 20), "the Keys screen should offer Add key")
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !add.isHittable { usleep(200_000) }
        add.tap()
        guard tapMenuItem("generate-key", in: app) else {
            XCTFail("the add-key menu should offer Generate"); return
        }
        let field = app.textFields["key-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 12), "the sheet should ask for a name")
        field.tap()
        field.typeText(name)
        if inEnclave {
            let choice = app.descendants(matching: .any).matching(identifier: "key-storage-enclave").firstMatch
            if choice.waitForExistence(timeout: 6), choice.isHittable { choice.tap() }
        }
        app.buttons["key-generate"].tap()
        let done = app.buttons["key-dismiss"]
        XCTAssertTrue(done.waitForExistence(timeout: 25), "generating should land on the new key")
        done.tap()
    }

    /// Scrolls the Settings form until `element` can actually be tapped.
    ///
    /// Searches both ways. A helper that only swipes up finds a row below the fold and
    /// never one above it, and where the form is a sheet — which it is on an iPad — a
    /// row's centre can sit under the navigation bar while `isHittable` still says yes,
    /// so a tap at that centre lands on the bar and opens nothing. Row heights differ
    /// between languages, which is why this failed in Chinese and not in English.
    private func scrollSettings(of app: XCUIApplication, to element: XCUIElement, attempts: Int = 14) -> Bool {
        let form = app.collectionViews["settings-form"].firstMatch
        _ = form.waitForExistence(timeout: 10)
        let target = form.exists ? form : app.collectionViews.firstMatch

        func tappable() -> Bool {
            guard element.exists, element.isHittable else { return false }
            guard form.exists else { return true }
            let bars = app.navigationBars.allElementsBoundByIndex.filter { form.frame.intersects($0.frame) }
            let top = bars.map(\.frame.maxY).max() ?? form.frame.minY
            let centre = element.frame.midY
            return centre >= top && centre <= form.frame.maxY
        }

        for up in [true, false] {
            for _ in 0 ..< attempts {
                if tappable() { return true }
                if up { target.swipeUp() } else { target.swipeDown() }
            }
        }
        return tappable()
    }

    // MARK: - 08 · The desktop

    func test08Desktop() throws {
        let app = launch()
        let screen = app.buttons.matching(identifier: "screen-row").firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 25), "the saved screen should be listed")
        screen.tap()
        // Matched on the identifier across every element type: the view sets
        // `accessibilityTraits = .image`, but which query class that lands in has moved
        // between OS versions, and a capture should not be hostage to that.
        let desktop = app.descendants(matching: .any).matching(identifier: "vnc-screen").firstMatch
        if !waitForDesktop(app) {
            // Say what was on screen instead, so a failure is diagnosable without a rerun.
            let connecting = app.descendants(matching: .any).matching(identifier: "vnc-connecting").firstMatch
            let state = connecting.exists ? "still connecting" : "neither connecting nor connected"
            capture("08-desktop-FAILED")
            XCTFail("the remote desktop never appeared — \(state). Screen was:\n\(app.debugDescription.prefix(3000))")
            return
        }
        capture("08-desktop")
    }
}
