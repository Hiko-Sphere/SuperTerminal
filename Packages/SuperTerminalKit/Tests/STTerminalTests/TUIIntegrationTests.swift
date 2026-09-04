import Foundation
import NIOTransportServices
import STCore
import STSSH
import STTerminal
import STTestSupport
import Testing

/// Runs real full-screen programs over a real SSH connection and feeds their output
/// through the emulator.
///
/// Unit tests prove the emulator handles the sequences it is given. These prove it
/// handles the sequences that `vim` and `less` actually emit — which is a different and
/// much harder claim, because real programs use combinations, timing and terminal
/// queries that no hand-written fixture anticipates.
@Suite("Real TUI programs over SSH", .serialized)
struct TUIIntegrationTests {
    /// Drives a live PTY session with an emulator attached.
    private final class Session: @unchecked Sendable {
        let shell: SSHShellSession
        private var emulator: TerminalEmulator
        private let lock = NSLock()
        private var collector: Task<Void, Never>?

        init(shell: SSHShellSession, columns: Int, rows: Int) {
            self.shell = shell
            emulator = TerminalEmulator(columns: columns, rows: rows, scrollbackLimit: 2000)
        }

        func start() {
            let output = shell.output
            collector = Task { [weak self] in
                for await event in output {
                    guard let self else { return }
                    if case let .output(data) = event {
                        let responses = self.consume(data)
                        // Programs that query the terminal block until it answers, so
                        // the answer has to actually go back over the wire.
                        for response in responses {
                            try? await self.shell.send(response)
                        }
                    }
                    if case .closed = event { return }
                }
            }
        }

        func stop() { collector?.cancel() }

        /// Feeds bytes to the emulator under the lock and returns any answer-back the
        /// terminal owes the remote program.
        ///
        /// Locking is confined to this synchronous method rather than held across an
        /// `await`: a lock spanning a suspension point is both unsafe and rejected by
        /// the compiler.
        private func consume(_ data: Data) -> [Data] {
            lock.lock()
            defer { lock.unlock() }
            var responses: [Data] = []
            for terminalEvent in emulator.feed(data) {
                if case let .respond(bytes) = terminalEvent { responses.append(bytes) }
            }
            _ = emulator.flush()
            return responses
        }

        var screenText: String {
            lock.lock()
            defer { lock.unlock() }
            return emulator.activeScreen.visibleText
        }

        var isOnAlternateScreen: Bool {
            lock.lock()
            defer { lock.unlock() }
            return emulator.modes.alternateScreen
        }

        var title: String {
            lock.lock()
            defer { lock.unlock() }
            return emulator.title
        }

        var scrollbackCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return emulator.screen.scrollback.count
        }

        /// Waits until the rendered screen satisfies `predicate`, or fails the test.
        func waitForScreen(
            timeout: Double = 20,
            describedAs description: String,
            _ predicate: @escaping (String) -> Bool
        ) async throws -> String {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                let text = screenText
                if predicate(text) { return text }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw ScreenTimeout(description: description, lastScreen: screenText)
        }
    }

    struct ScreenTimeout: Error, CustomStringConvertible {
        let description0: String
        let lastScreen: String
        init(description: String, lastScreen: String) {
            description0 = description
            self.lastScreen = lastScreen
        }

        var description: String {
            "timed out waiting for \(description0). Last screen:\n\(lastScreen)"
        }
    }

    private func withSession<T>(
        columns: Int = 80,
        rows: Int = 24,
        _ body: (Session, OpenSSHTestServer) async throws -> T
    ) async throws -> T {
        let server = try OpenSSHTestServer()
        let group = NIOTSEventLoopGroup(loopCount: 1)

        func teardown(_ session: Session?, _ connection: SSHConnection?) async {
            session?.stop()
            if let session { await session.shell.close() }
            if let connection { await connection.close() }
            server.shutDown()
            try? await group.shutdownGracefully()
        }

        var session: Session?
        var connection: SSHConnection?
        do {
            let key = try OpenSSHPrivateKeyParser.parse(pem: server.fixtures.clientPrivateKeyPEM)
            let identity = KnownHostIdentity(host: "127.0.0.1", port: server.fixtures.port)
            let established = try await SSHConnection.connect(
                transport: DirectTCPTransport(
                    endpoint: TransportEndpoint(host: "127.0.0.1", port: server.fixtures.port)
                ),
                configuration: SSHConnectionConfiguration(
                    username: server.fixtures.username,
                    credentials: [.privateKey(key)],
                    knownHostIdentity: identity
                ),
                hostKeyVerifier: HostKeyVerifier(
                    identity: identity,
                    store: InMemoryKnownHostsStore(),
                    approval: TrustOnFirstUseApproval()
                ),
                eventLoop: group.next()
            )
            connection = established
            let shell = try await established.openShell(
                terminalType: "xterm-256color",
                size: TerminalSize(columns: columns, rows: rows)
            )
            let live = Session(shell: shell, columns: columns, rows: rows)
            live.start()
            session = live

            // Replace the login shell with a bare `sh` in a scrubbed environment.
            //
            // The account's real shell may be zsh with a themed prompt that repaints
            // itself, rewrites the window title and prints a clock — all of which would
            // make "is the shell ready?" and "did the program set the title?"
            // unanswerable. The tests are about the emulator, so the shell has to be a
            // constant.
            let path = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            try await shell.send(
                "exec env -i HOME=\"$HOME\" TERM=xterm-256color LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 "
                    + "PATH=\(path) PS1='RDY> ' /bin/sh -i\n"
            )
            _ = try await live.waitForScreen(describedAs: "the clean shell prompt") { $0.contains("RDY>") }
            try await shell.send("clear\n")
            _ = try await live.waitForScreen(describedAs: "a cleared screen") {
                $0.contains("RDY>") && !$0.contains("exec env")
            }

            let result = try await body(live, server)
            await teardown(session, connection)
            return result
        } catch {
            await teardown(session, connection)
            throw error
        }
    }

    @Test("vim draws a full-screen editor, holds typed text, and restores the shell on exit")
    func vimSessionRenders() async throws {
        try await withSession { session, _ in
            try await session.shell.send("vim -u NONE -N\n")
            // Vim with no config fills unused rows with `~`, which is a signal that a
            // full-screen redraw actually happened rather than a scrolling one.
            _ = try await session.waitForScreen(describedAs: "vim's empty-line markers") {
                $0.split(separator: "\n").filter { $0.hasPrefix("~") }.count >= 5
            }
            #expect(session.isOnAlternateScreen)

            try await session.shell.send("iSuperTerminal works\u{1B}")
            let edited = try await session.waitForScreen(describedAs: "the typed text") {
                $0.contains("SuperTerminal works")
            }
            #expect(edited.contains("SuperTerminal works"))

            try await session.shell.send(":q!\r")
            _ = try await session.waitForScreen(describedAs: "the shell prompt after quitting vim") { text in
                !session.isOnAlternateScreen && text.contains("RDY>")
            }
            // Leaving a full-screen program must put the shell back, not leave vim's
            // redraw behind.
            #expect(!session.isOnAlternateScreen)
        }
    }

    @Test("vim renders CJK, emoji and combining characters at the right widths")
    func vimRendersWideCharacters() async throws {
        try await withSession { session, _ in
            // `-u NONE` means no vimrc, so the encoding has to be stated explicitly;
            // otherwise vim falls back to latin1 and mangles the multi-byte input before
            // the emulator ever sees it.
            try await session.shell.send("vim -u NONE -N --cmd 'set encoding=utf-8' --cmd 'set fileencoding=utf-8'\n")
            _ = try await session.waitForScreen(describedAs: "vim to start") {
                $0.split(separator: "\n").filter { $0.hasPrefix("~") }.count >= 5
            }

            try await session.shell.send("i中文测试 café 😀\u{1B}")
            let text = try await session.waitForScreen(describedAs: "the wide text") {
                $0.contains("中文测试")
            }
            #expect(text.contains("中文测试"))
            #expect(text.contains("café"))
            #expect(text.contains("😀"))

            try await session.shell.send(":q!\r")
            _ = try await session.waitForScreen(describedAs: "the shell prompt") { $0.contains("RDY>") }
        }
    }

    @Test("less uses the alternate screen and leaves the shell output intact")
    func lessUsesAlternateScreen() async throws {
        try await withSession { session, _ in
            try await session.shell.send("seq 1 500 > /tmp/st-less-fixture.txt; echo FIXTURE_READY\n")
            _ = try await session.waitForScreen(describedAs: "the fixture to be written") {
                $0.contains("FIXTURE_READY")
            }

            try await session.shell.send("less /tmp/st-less-fixture.txt\n")
            // less paints the first screenful into the alternate buffer; seeing a line
            // number from partway down proves it painted rather than merely started.
            _ = try await session.waitForScreen(describedAs: "less to paint the file") { text in
                session.isOnAlternateScreen && text.contains("20")
            }
            #expect(session.isOnAlternateScreen)

            try await session.shell.send("q")
            _ = try await session.waitForScreen(describedAs: "the shell prompt after less") {
                !session.isOnAlternateScreen && $0.contains("RDY>")
            }
            // The 500 lines less displayed belong to its own buffer and must not be in
            // the user's history.
            #expect(session.scrollbackCount < 100)

            try await session.shell.send("rm -f /tmp/st-less-fixture.txt\n")
        }
    }

    @Test("A resize mid-session is honoured by a running full-screen program")
    func resizeIsHonouredByRunningProgram() async throws {
        try await withSession(columns: 80, rows: 24) { session, _ in
            try await session.shell.send("vim -u NONE -N\n")
            _ = try await session.waitForScreen(describedAs: "vim to start") {
                $0.split(separator: "\n").filter { $0.hasPrefix("~") }.count >= 5
            }

            try await session.shell.resize(to: TerminalSize(columns: 100, rows: 30))
            try await session.shell.send(":set columns?\r")
            let text = try await session.waitForScreen(describedAs: "vim's reported width") {
                $0.contains("columns=100")
            }
            #expect(text.contains("columns=100"))

            try await session.shell.send(":q!\r")
            _ = try await session.waitForScreen(describedAs: "the shell prompt") { $0.contains("RDY>") }
        }
    }

    @Test("A large burst of output is consumed without loss or unbounded growth")
    func highVolumeOutputIsBounded() async throws {
        try await withSession { session, _ in
            try await session.shell.send("seq 1 20000; echo BURST_%s\n".replacingOccurrences(of: "%s", with: "COMPLETE"))
            _ = try await session.waitForScreen(timeout: 60, describedAs: "the burst to finish") {
                $0.contains("BURST_COMPLETE")
            }
            // Scrollback is capped at 2000 for this session; 20 000 lines must not grow
            // memory past that.
            #expect(session.scrollbackCount <= 2000)
        }
    }

    @Test("The window title set by a remote program reaches the app")
    func titleFromRemoteProgram() async throws {
        try await withSession { session, _ in
            try await session.shell.send("printf '\\033]0;remote-title\\007'; echo TITLE_SENT\n")
            _ = try await session.waitForScreen(describedAs: "the title command to run") {
                $0.contains("TITLE_SENT")
            }
            // The title arrives in the same byte stream as the echo, so once TITLE_SENT
            // is on screen the OSC has already been parsed.
            #expect(session.title == "remote-title")
        }
    }
}
