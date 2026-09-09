import Foundation
import STCore
import STSSH
import STTmux
import Testing

@testable import ApexTerminal

/// tmux in the app (D-059): the record, the routing, and a real attach.
@Suite struct TmuxHostRecordTests {
    @Test("A connection written before tmux existed still decodes, and reads as off")
    func decodesOlderRecords() throws {
        // The field is optional for exactly this reason: a synthesized decoder throws on a
        // missing key otherwise, and every connection anybody has saved predates it. Built
        // by encoding a real record and removing the keys, so the rest of the JSON is
        // whatever the app actually writes rather than a hand-typed approximation that
        // could fail for an unrelated reason.
        let original = Host(name: "old", hostname: "example.com", username: "deploy", usesTmux: true, tmuxSessionName: "work")
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any]
        )
        #expect(object["usesTmux"] != nil, "the field is written when it is set")
        object.removeValue(forKey: "usesTmux")
        object.removeValue(forKey: "tmuxSessionName")

        let older = try JSONSerialization.data(withJSONObject: object)
        let host = try JSONDecoder().decode(Host.self, from: older)
        #expect(!host.isUsingTmux)
        #expect(host.tmuxSessionName == nil)
    }

    @Test("The editor's tmux fields round-trip, and a name without tmux is dropped")
    func editorFieldsRoundTrip() {
        let host = Host(name: "server", hostname: "example.com", port: 22, username: "deploy")
        var fields = HostEditorFields(
            name: "server", hostname: "example.com", port: 22, username: "deploy",
            transport: .directTCP, credentials: [], folder: nil, terminalType: "xterm-256color",
            accessAuthentication: nil, platformOverride: nil, showsInFiles: false,
            jumpHosts: [], forwardsAgent: false, usesTmux: true, tmuxSessionName: " work "
        )
        let withTmux = host.applying(fields)
        #expect(withTmux.isUsingTmux)
        #expect(withTmux.tmuxSessionName == "work", "the name is trimmed")

        // Turning tmux off must not leave the name behind: it would come back with the
        // toggle and attach somewhere the user did not choose.
        fields.usesTmux = false
        let without = withTmux.applying(fields)
        #expect(!without.isUsingTmux)
        #expect(without.tmuxSessionName == nil)
    }

    @Test("A session name is quoted for the remote shell")
    func quotesSessionNames() {
        // The name reaches a shell, so a quote in it must not end the argument. Not
        // theoretical: tmux allows spaces and quotes in session names.
        #expect(TmuxSession.quoted("work") == "'work'")
        #expect(TmuxSession.quoted("my work") == "'my work'")
        #expect(TmuxSession.quoted("it's") == #"'it'\''s'"#)
    }
}

@Suite @MainActor struct TmuxRoutingTests {
    @Test("Showing a tmux session replaces whatever the window was showing")
    func showingReplaces() {
        let scene = SceneState()
        let terminal = UUID()
        scene.show(terminal: terminal)
        #expect(scene.panes.panes.map(\.content) == [.terminal(terminal)])

        let tmux = UUID()
        scene.show(tmux: tmux)
        #expect(scene.selectedTmuxSessionID == tmux)
        #expect(scene.selectedSessionID == nil, "a window shows one thing at a time")
        #expect(scene.selectedScreenID == nil)
        #expect(scene.panes.panes.map(\.content) == [.tmux(tmux)])
    }

    @Test("A tmux pane is its own kind of content, and carries its id")
    func contentCarriesTheID() {
        let id = UUID()
        #expect(PaneLayout.Content.tmux(id).sessionID == id)
        #expect(PaneLayout.Content.tmux(id) != PaneLayout.Content.terminal(id),
                "a tmux session and a terminal with the same id are not the same pane")
    }
}

/// The app's tmux session against a real tmux, over a real SSH connection.
@Suite(.serialized) @MainActor struct TmuxAttachTests {
    private struct Fixtures {
        let port: Int
        let username: String
        let password: String
    }

    private func fixtures() throws -> Fixtures {
        let environment = ProcessInfo.processInfo.environment
        guard let portText = environment["ST_APP_TEST_TMUX_PORT"], let port = Int(portText),
              let username = environment["ST_APP_TEST_TMUX_USER"], !username.isEmpty,
              let password = environment["ST_APP_TEST_TMUX_PASSWORD"], !password.isEmpty
        else {
            throw XCTSkipLike.needsTheContainer
        }
        return Fixtures(port: port, username: username, password: password)
    }

    enum XCTSkipLike: Error { case needsTheContainer }

    /// Waits for a condition on the main actor, driven by polling the session's state.
    private func wait(
        timeout: Duration = .seconds(30),
        until condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    @Test("Attaching produces windows, panes and terminals", .timeLimit(.minutes(3)))
    func attaches() async throws {
        let fixtures: Fixtures
        do { fixtures = try self.fixtures() } catch { return }

        let vault = CredentialVault()
        let host = Host(
            name: "tmux", hostname: "127.0.0.1", port: fixtures.port,
            username: fixtures.username, credentials: [.password], usesTmux: true,
            tmuxSessionName: "apextest"
        )
        try vault.storePassword(fixtures.password, hostID: host.id)
        defer { try? vault.deletePassword(hostID: host.id) }

        // An in-memory known-hosts store, so the container's fresh host key is accepted on
        // first use without a prompt — the prompt path is the connection's own and is
        // covered where it belongs.
        let manager = SessionManager(
            vault: vault,
            knownHosts: InMemoryKnownHostsStore(),
            settings: AppSettings(defaults: UserDefaults(suiteName: "tmux-\(UUID())")!),
            diagnostics: DiagnosticsCentre()
        )
        let made = manager.makeTmuxConnector(for: host)
        let session = TmuxSession(host: host, connector: made.connector, prompts: made.prompts)

        // Answering as a person would: the container's host key has never been seen, so
        // the first connection asks about it. Approving it here is the real path — the one
        // that would otherwise wait forever — rather than a store pre-seeded to skip the
        // question.
        let answering = Task { @MainActor in
            while !Task.isCancelled {
                if case .unknownHostKey = session.pendingPrompt {
                    session.resolvePrompt(.approve)
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        defer { answering.cancel() }

        await session.connect()
        let attached = await wait { if case .attached = session.state { return true }; return false }
        #expect(attached, "state was \(session.state)")

        let hasPanes = await wait { session.activeWindow?.panes.isEmpty == false }
        #expect(hasPanes, "a fresh tmux session has one window with one pane")
        let pane = try #require(session.activeWindow?.panes.first)
        #expect(session.snapshot?.terminal(for: pane) != nil, "the pane should have a terminal")

        // Typed as a person would, and read back from the terminal the view draws.
        await session.send(Data("printf 'APP_%s\n' TMUX\n".utf8), to: pane)
        let printed = await wait {
            session.snapshot?.terminal(for: pane)?.activeScreen.visibleText.contains("APP_TMUX") == true
        }
        #expect(printed, "what the shell printed should reach the pane's terminal")

        // Splitting is tmux's, and the app must see the result rather than its own idea of
        // a layout: two panes, each with a terminal.
        await session.splitVertically()
        let split = await wait {
            guard let window = session.activeWindow, window.panes.count == 2 else { return false }
            return window.panes.allSatisfy { session.snapshot?.terminal(for: $0) != nil }
        }
        #expect(split, "the split should reach the app as a second pane with its own terminal")

        // Scrolling is tmux's copy mode, not a local buffer: the app never had the lines
        // above the screen, so a client that scrolled its own emulator would scroll
        // nothing. Printing two hundred lines and scrolling up must reveal earlier ones.
        await session.send(Data("seq 1 200\n".utf8), to: pane)
        let printedAll = await wait {
            session.snapshot?.terminal(for: pane)?.activeScreen.visibleText.contains("200") == true
        }
        #expect(printedAll, "the pane should show the end of the output")

        // Scrolling is local, over the history the pane's terminal was seeded with — tmux's
        // own copy mode sends a control client nothing at all, which is why it is not used.
        session.scroll(40, in: pane)
        #expect(session.scrollOffsets[pane] == 40, "the pane should be scrolled back")
        // And it cannot be scrolled past what there is.
        session.scroll(100_000, in: pane)
        let atTop = try #require(session.scrollOffsets[pane])
        let history = try #require(session.snapshot?.terminal(for: pane)?.activeScreen.scrollback.count)
        #expect(atTop == history, "scrolling stops at the oldest line there is")
        #expect(history > 40, "two hundred lines of output should leave history to scroll")

        // Typing brings it back to the newest output, which is where the keystroke lands.
        await session.send(Data("\n".utf8), to: pane)
        #expect(session.scrollOffsets[pane] == 0)

        // Detaching leaves the work running: that is the whole point of tmux, so the
        // session is asked to detach rather than to kill anything.
        await session.detach()
        #expect({ if case .detached = session.state { return true }; return false }())
    }
}

/// The UI harness's seeding, checked without a simulator run.
///
/// Worth its own test because the failure mode is silent: a variable the harness sets and
/// the app does not read leaves a run testing an app with no tmux connection in it, which
/// looks exactly like tmux being broken.
@Suite(.serialized) struct TmuxSeedingTests {
    @Test("A tmux connection is seeded when the harness provides a server")
    func seedsATmuxHost() throws {
        let previous = ProcessInfo.processInfo.environment
        setenv("ST_UITEST_SEED", "1", 1)
        setenv("ST_UITEST_HOST", "127.0.0.1", 1)
        setenv("ST_UITEST_PORT", "2222", 1)
        setenv("ST_UITEST_USER", "tester", 1)
        setenv("ST_UITEST_KEY", "-----BEGIN OPENSSH PRIVATE KEY-----\nx\n-----END OPENSSH PRIVATE KEY-----", 1)
        setenv("ST_UITEST_TMUX_PORT", "8500", 1)
        setenv("ST_UITEST_TMUX_USER", "tmuxtest", 1)
        setenv("ST_UITEST_TMUX_PASSWORD", "secret", 1)
        defer {
            for name in ["ST_UITEST_SEED", "ST_UITEST_HOST", "ST_UITEST_PORT", "ST_UITEST_USER",
                         "ST_UITEST_KEY", "ST_UITEST_TMUX_PORT", "ST_UITEST_TMUX_USER",
                         "ST_UITEST_TMUX_PASSWORD"] where previous[name] == nil {
                unsetenv(name)
            }
        }

        let seed = try #require(UITestSeeding.seedFromEnvironment)
        let tmuxHost = try #require(seed.tmuxHost, "the tmux connection should be seeded")
        #expect(tmuxHost.isUsingTmux)
        #expect(tmuxHost.port == 8500)
        #expect(tmuxHost.username == "tmuxtest")
        #expect(tmuxHost.credentials == [.password])
        #expect(seed.tmuxPassword == "secret")
    }

    @Test("With no tmux server, no tmux connection is seeded")
    func seedsNothingWithoutAServer() {
        unsetenv("ST_UITEST_TMUX_PORT")
        setenv("ST_UITEST_SEED", "1", 1)
        setenv("ST_UITEST_HOST", "127.0.0.1", 1)
        setenv("ST_UITEST_PORT", "2222", 1)
        setenv("ST_UITEST_USER", "tester", 1)
        setenv("ST_UITEST_KEY", "-----BEGIN OPENSSH PRIVATE KEY-----\nx\n-----END OPENSSH PRIVATE KEY-----", 1)
        defer { unsetenv("ST_UITEST_SEED") }
        #expect(UITestSeeding.seedFromEnvironment?.tmuxHost == nil)
    }
}
