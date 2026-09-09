import Foundation
import NIOTransportServices
import STCore
import STSSH
import STTestSupport
import Testing

@testable import STTmux

/// tmux control mode against a real tmux, over a real SSH connection (D-057).
///
/// Nothing here is simulated: an OpenSSH server in a container, a real `tmux -C` behind it,
/// and the client under test driving it through an exec channel. That is the whole product
/// path — the thing a person will use — and it is the only way to find out what tmux
/// actually sends, which differs from what the documentation implies in several places.
@Suite(
    "tmux control mode against a real server",
    .enabled(if: TmuxTestServer.isAvailable, "needs Docker running"),
    .serialized
)
struct TmuxIntegrationTests {
    /// Bridges the control session's writes onto the SSH channel.
    private struct ShellTransport: TmuxControlTransport {
        let shell: SSHShellSession
        func write(_ bytes: [UInt8]) async throws {
            try await shell.send(Data(bytes))
        }
    }

    /// Connects, starts tmux in control mode, and pumps the channel into the parser.
    private func attach(
        to server: TmuxTestServer,
        command: String = "tmux -C new-session -s apex"
    ) async throws -> (SSHConnection, SSHShellSession, TmuxControlSession, Task<Void, Never>) {
        let fixtures = server.fixtures
        let identity = KnownHostIdentity(host: fixtures.host, port: fixtures.port)
        let connection = try await SSHConnection.connect(
            transport: DirectTCPTransport(
                endpoint: TransportEndpoint(host: fixtures.host, port: fixtures.port)
            ),
            configuration: SSHConnectionConfiguration(
                username: fixtures.username,
                credentials: [.password(Redacted(fixtures.password, label: "ssh-password"))],
                knownHostIdentity: identity
            ),
            hostKeyVerifier: HostKeyVerifier(
                identity: identity,
                store: InMemoryKnownHostsStore(),
                approval: TrustOnFirstUseApproval()
            ),
            eventLoop: NIOTSEventLoopGroup.singleton.next()
        )
        let shell = try await connection.openCommand(command)
        let control = TmuxControlSession(transport: ShellTransport(shell: shell))
        let pump = Task {
            for await event in shell.output {
                switch event {
                case let .output(data): await control.receive(Array(data))
                case .errorOutput: break
                case .exit, .closed: await control.finish(reason: nil)
                }
            }
            await control.finish(reason: nil)
        }
        return (connection, shell, control, pump)
    }

    /// Waits for the first notification that matches, or gives up. Notifications and
    /// command replies race by nature — tmux does not wait for a client to be ready — so
    /// this waits on the stream rather than sleeping and hoping.
    private func waitFor(
        _ stream: AsyncStream<TmuxNotification>.Iterator,
        timeout: Duration = .seconds(30),
        matching: @escaping @Sendable (TmuxNotification) -> Bool
    ) async -> (TmuxNotification?, AsyncStream<TmuxNotification>.Iterator) {
        var iterator = stream
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            guard let notification = await iterator.next() else { return (nil, iterator) }
            if matching(notification) { return (notification, iterator) }
        }
        return (nil, iterator)
    }

    @Test("Attaching announces the window and the session, and commands are answered",
          .timeLimit(.minutes(3)))
    func attachesAndRunsCommands() async throws {
        let server = try TmuxTestServer()
        defer { server.shutDown() }
        let (connection, shell, control, pump) = try await attach(to: server)
        defer {
            pump.cancel()
            Task { await shell.close(); await connection.close() }
        }

        var iterator = control.notifications.makeAsyncIterator()
        let (added, next) = await waitFor(iterator) { if case .windowAdd = $0 { return true }; return false }
        iterator = next
        #expect(added != nil, "attaching should announce a window")

        // A command's reply comes back as its lines, and tmux's own version proves the
        // reply belongs to this command rather than to the attach block that precedes it.
        let version = try await control.send("display-message -p '#{version}'")
        #expect(version.count == 1)
        #expect(version.first?.first?.isNumber == true, "expected a version, got \(version)")

        // The window is real, and named.
        let windows = try await control.send("list-windows")
        #expect(windows.contains { $0.contains("@0") }, "expected @0 in \(windows)")
    }

    @Test("A refused command reports what tmux said rather than hanging", .timeLimit(.minutes(3)))
    func refusedCommandsThrow() async throws {
        let server = try TmuxTestServer()
        defer { server.shutDown() }
        let (connection, shell, control, pump) = try await attach(to: server)
        defer {
            pump.cancel()
            Task { await shell.close(); await connection.close() }
        }

        do {
            _ = try await control.send("not-a-command")
            Issue.record("expected the command to be refused")
        } catch let TmuxError.commandFailed(command, message) {
            #expect(command == "not-a-command")
            // tmux puts the message in the block before %error; a client that read only the
            // %error line would have nothing to show the user.
            #expect(message.contains("unknown command"), "got \(message)")
        }

        // And the session still works afterwards, which is the part that breaks when a
        // failed command is left in the queue.
        let version = try await control.send("display-message -p '#{version}'")
        #expect(version.count == 1)
    }

    @Test("Splitting a window produces a layout that parses and holds two panes",
          .timeLimit(.minutes(3)))
    func splittingChangesTheLayout() async throws {
        let server = try TmuxTestServer()
        defer { server.shutDown() }
        let (connection, shell, control, pump) = try await attach(to: server)
        defer {
            pump.cancel()
            Task { await shell.close(); await connection.close() }
        }

        var iterator = control.notifications.makeAsyncIterator()
        let (_, afterAdd) = await waitFor(iterator) { if case .windowAdd = $0 { return true }; return false }
        iterator = afterAdd

        try await control.send("split-window")
        let (change, afterChange) = await waitFor(iterator) {
            if case .layoutChange = $0 { return true }
            return false
        }
        iterator = afterChange
        guard case let .layoutChange(window, layout, _, _)? = change else {
            Issue.record("expected a layout change")
            return
        }
        #expect(window == TmuxWindowID(0))

        // The checksum is verified by the parser, so this passing means the layout arrived
        // intact and is the arrangement the server has — not a plausible reading of it.
        let parsed = try TmuxLayout.parse(layout)
        #expect(parsed.panes.count == 2, "a split window has two panes, got \(parsed.panes)")
        #expect(parsed.panes.map(\.id) == [TmuxPaneID(0), TmuxPaneID(1)])
        // Splitting with no argument stacks them, so the second pane starts below the first.
        #expect(parsed.panes[1].frame.y > parsed.panes[0].frame.y)
    }

    @Test("What a pane prints arrives as output for that pane", .timeLimit(.minutes(3)))
    func paneOutputArrives() async throws {
        let server = try TmuxTestServer()
        defer { server.shutDown() }
        let (connection, shell, control, pump) = try await attach(to: server)
        defer {
            pump.cancel()
            Task { await shell.close(); await connection.close() }
        }

        var iterator = control.notifications.makeAsyncIterator()
        let (_, afterAdd) = await waitFor(iterator) { if case .windowAdd = $0 { return true }; return false }
        iterator = afterAdd

        // Built by the shell rather than typed whole, so the marker in the assertion cannot
        // match the echo of the command that produced it.
        try await control.send(#"send-keys -t 0 "printf 'TMUX_%s\n' OK" Enter"#)
        let (output, _) = await waitFor(iterator) { notification in
            guard case let .output(_, bytes) = notification else { return false }
            return String(decoding: bytes, as: UTF8.self).contains("TMUX_OK")
        }
        guard case let .output(pane, bytes)? = output else {
            Issue.record("the pane's output never arrived")
            return
        }
        #expect(pane == TmuxPaneID(0))
        // The escaping is undone: a carriage return arrives as a byte, not as `\015`.
        #expect(bytes.contains(0x0D) || bytes.contains(0x0A))
    }

    @Test("Killing the session ends the stream and fails what was waiting",
          .timeLimit(.minutes(3)))
    func killingEndsTheSession() async throws {
        let server = try TmuxTestServer()
        defer { server.shutDown() }
        let (connection, shell, control, pump) = try await attach(to: server)
        defer {
            pump.cancel()
            Task { await shell.close(); await connection.close() }
        }

        var iterator = control.notifications.makeAsyncIterator()
        let (_, afterAdd) = await waitFor(iterator) { if case .windowAdd = $0 { return true }; return false }
        iterator = afterAdd

        // `kill-session` answers first and then the server goes away, so this is not an
        // error; what matters is that the client notices the exit rather than waiting.
        _ = try? await control.send("kill-session")
        let (exit, _) = await waitFor(iterator) { if case .exit = $0 { return true }; return false }
        #expect(exit != nil, "the client should see %exit")

        await #expect(throws: TmuxError.self) {
            _ = try await control.send("list-windows")
        }
    }
}
