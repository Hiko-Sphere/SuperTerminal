import Foundation
import NIOTransportServices
import STCore
import STSSH
import STTerminal
import STTestSupport
import Testing

@testable import STTmux

/// The workspace — windows, panes and a terminal each — against a real tmux (D-057).
///
/// Everything here is measured rather than asserted from the manual, because the two
/// behaviours that matter most are ones tmux does not document: reattaching to a session
/// announces almost nothing, and pane discovery happens through the layout rather than
/// through any per-pane notification.
@Suite(
    "tmux workspace against a real server",
    .enabled(if: TmuxTestServer.isAvailable, "needs Docker running"),
    .serialized
)
struct TmuxWorkspaceTests {
    private struct ShellTransport: TmuxControlTransport {
        let shell: SSHShellSession
        func write(_ bytes: [UInt8]) async throws { try await shell.send(Data(bytes)) }
    }

    private func connect(to server: TmuxTestServer) async throws -> SSHConnection {
        let fixtures = server.fixtures
        let identity = KnownHostIdentity(host: fixtures.host, port: fixtures.port)
        return try await SSHConnection.connect(
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
    }

    private func workspace(
        on connection: SSHConnection,
        command: String
    ) async throws -> (TmuxWorkspace, SSHShellSession, Task<Void, Never>) {
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
        let workspace = TmuxWorkspace(control: control, size: (100, 30))
        try await workspace.attach()
        return (workspace, shell, pump)
    }

    /// Waits until the workspace satisfies a condition, driven by its own events rather
    /// than by sleeping.
    private func wait(
        on workspace: TmuxWorkspace,
        timeout: Duration = .seconds(30),
        until condition: @escaping @Sendable (TmuxWorkspace) async -> Bool
    ) async -> Bool {
        if await condition(workspace) { return true }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        for await _ in workspace.events {
            if await condition(workspace) { return true }
            if ContinuousClock.now > deadline { return false }
        }
        return await condition(workspace)
    }

    @Test("A fresh session has one window with one pane, and a terminal for it",
          .timeLimit(.minutes(3)))
    func freshSession() async throws {
        let server = try TmuxTestServer()
        defer { server.shutDown() }
        let connection = try await connect(to: server)
        let (workspace, shell, pump) = try await workspace(on: connection, command: "tmux -C new-session -s fresh")
        defer {
            pump.cancel()
            Task { await shell.close(); await connection.close() }
        }

        let windows = await workspace.windows
        #expect(windows.count == 1)
        let window = try #require(windows.first)
        #expect(window.panes.count == 1)
        // The client asked for 100x30 on attach, and tmux sized the window to it — which is
        // what makes the pane's terminal the size of what the user is looking at.
        #expect(window.layout.frame.width == 100)
        #expect(window.layout.frame.height == 30)
        let terminal = await workspace.terminal(for: window.panes[0])
        #expect(terminal != nil, "every pane should have a terminal")
    }

    @Test("Reattaching finds windows that were already there", .timeLimit(.minutes(3)))
    func reattachSeesExistingWindows() async throws {
        // The behaviour this exists for: attaching to a session that already has windows
        // announces `%session-changed` and nothing else — no `%window-add` for any of them.
        // A client that listened only to notifications would show an empty workspace over a
        // session full of work, so the state is primed with `list-windows`.
        let server = try TmuxTestServer()
        defer { server.shutDown() }
        let connection = try await connect(to: server)

        _ = try await connection.execute(command: "tmux new-session -d -s pre")
        _ = try await connection.execute(command: "tmux new-window -t pre")
        _ = try await connection.execute(command: "tmux split-window -t pre")

        let (workspace, shell, pump) = try await workspace(on: connection, command: "tmux -C attach-session -t pre")
        defer {
            pump.cancel()
            Task { await shell.close(); await connection.close() }
        }

        let windows = await workspace.windows
        #expect(windows.count == 2, "both windows should be found, got \(windows.map(\.id))")
        #expect(windows.map(\.panes.count).sorted() == [1, 2], "the split should be seen as two panes")
        for window in windows {
            for pane in window.panes {
                #expect(await workspace.terminal(for: pane) != nil, "\(pane) has no terminal")
            }
        }
    }

    @Test("Reattaching shows what a pane already had on it", .timeLimit(.minutes(3)))
    func reattachShowsExistingContents() async throws {
        // The behaviour this exists for: control mode sends `%output` only for what a pane
        // writes *from now on*. A client that relied on it would show a blank pane over a
        // session that has been running for a week, which is the opposite of why anybody
        // uses tmux.
        let server = try TmuxTestServer()
        defer { server.shutDown() }
        let connection = try await connect(to: server)

        _ = try await connection.execute(command: "tmux new-session -d -s history")
        _ = try await connection.execute(
            command: #"tmux send-keys -t history "printf 'BEFORE_%s\n' ATTACH" Enter"#
        )
        // Long enough for the shell to have run it; the assertion below is what proves it.
        try await Task.sleep(for: .seconds(2))

        let (workspace, shell, pump) = try await workspace(
            on: connection, command: "tmux -C attach-session -t history"
        )
        defer {
            pump.cancel()
            Task { await shell.close(); await connection.close() }
        }

        let showed = await wait(on: workspace) { workspace in
            let snapshot = await workspace.snapshot()
            guard let pane = snapshot.windows.first?.panes.first,
                  let terminal = snapshot.terminal(for: pane) else { return false }
            return terminal.activeScreen.visibleText.contains("BEFORE_ATTACH")
        }
        #expect(showed, "the pane should show what was printed before this client attached")
    }

    @Test("Splitting adds a pane and a terminal for it", .timeLimit(.minutes(3)))
    func splittingAddsAPane() async throws {
        let server = try TmuxTestServer()
        defer { server.shutDown() }
        let connection = try await connect(to: server)
        let (workspace, shell, pump) = try await workspace(on: connection, command: "tmux -C new-session -s split")
        defer {
            pump.cancel()
            Task { await shell.close(); await connection.close() }
        }

        try await workspace.perform("split-window")
        // Settled, not merely changed: the panes appear, and every one of them has a
        // terminal sized as tmux says that pane is — the two halves of a 30-row window are
        // not 30 rows each. Waiting on the whole condition rather than on the pane count
        // is what makes this deterministic; a split arrives as more than one notification,
        // and reading the sizes after the first of them catches the state mid-change.
        let settled = await wait(on: workspace) { workspace in
            let snapshot = await workspace.snapshot()
            guard let window = snapshot.windows.first, window.panes.count == 2 else { return false }
            return window.panes.allSatisfy { pane in
                guard let size = snapshot.size(of: pane) else { return false }
                return size.rows > 0 && size.rows < 30
            }
        }
        #expect(settled, "the split should appear as two panes, each with a terminal its own size")

        // And one read of the settled state says the same thing, which is what a view would
        // draw from.
        let snapshot = await workspace.snapshot()
        let window = try #require(snapshot.windows.first)
        #expect(window.panes.count == 2)
        let heights = window.panes.map { snapshot.size(of: $0)?.rows ?? 0 }
        #expect(heights.reduce(0, +) < 30, "two panes share the window's rows, got \(heights)")
    }

    @Test("The active pane is tmux's, not a guess", .timeLimit(.minutes(3)))
    func activePaneFollowsTmux() async throws {
        let server = try TmuxTestServer()
        defer { server.shutDown() }
        let connection = try await connect(to: server)
        let (workspace, shell, pump) = try await workspace(on: connection, command: "tmux -C new-session -s active")
        defer {
            pump.cancel()
            Task { await shell.close(); await connection.close() }
        }

        try await workspace.perform("split-window")
        // Splitting makes the *new* pane active, which a client that assumed "the first
        // one" would get wrong — and then its focus ring would sit on one pane while every
        // tmux command acted on another.
        let selected = await wait(on: workspace) { workspace in
            let snapshot = await workspace.snapshot()
            guard let window = snapshot.windows.first, window.panes.count == 2 else { return false }
            return window.activePane == window.panes[1]
        }
        #expect(selected, "the new pane should be the active one")

        try await workspace.perform("select-pane -t 0")
        let movedBack = await wait(on: workspace) { workspace in
            let snapshot = await workspace.snapshot()
            guard let window = snapshot.windows.first else { return false }
            return window.activePane == window.panes.first
        }
        #expect(movedBack, "selecting a pane should move the active one")
    }

    @Test("What is typed reaches the shell, and what it prints reaches the terminal",
          .timeLimit(.minutes(3)))
    func inputAndOutputRoundTrip() async throws {
        let server = try TmuxTestServer()
        defer { server.shutDown() }
        let connection = try await connect(to: server)
        let (workspace, shell, pump) = try await workspace(on: connection, command: "tmux -C new-session -s io")
        defer {
            pump.cancel()
            Task { await shell.close(); await connection.close() }
        }

        let pane = try #require(await workspace.windows.first?.panes.first)
        // Typed as bytes, the way a keyboard sends them — including the return.
        try await workspace.send(Array("printf 'ROUND_%s\n' TRIP\n".utf8), to: pane)

        let arrived = await wait(on: workspace) { workspace in
            guard let terminal = await workspace.terminal(for: pane) else { return false }
            return terminal.activeScreen.visibleText.contains("ROUND_TRIP")
        }
        #expect(arrived, "the pane's terminal should show what the shell printed")
    }

    @Test("Resizing the client resizes the panes", .timeLimit(.minutes(3)))
    func resizing() async throws {
        let server = try TmuxTestServer()
        defer { server.shutDown() }
        let connection = try await connect(to: server)
        let (workspace, shell, pump) = try await workspace(on: connection, command: "tmux -C new-session -s size")
        defer {
            pump.cancel()
            Task { await shell.close(); await connection.close() }
        }

        try await workspace.setClientSize(columns: 132, rows: 43)
        let resized = await wait(on: workspace) { workspace in
            await workspace.windows.first?.layout.frame.width == 132
        }
        #expect(resized, "tmux should size the window to the client")
        // And it stays sized: an in-flight `list-windows` from before the change must not
        // land afterwards and put the old layout back, which is what happened until reloads
        // were serialised and stale answers discarded.
        let window = try #require(await workspace.windows.first)
        #expect(window.layout.frame.width == 132)
        #expect(window.layout.frame.height == 43)

        let pane = try #require(await workspace.windows.first?.panes.first)
        let terminal = try #require(await workspace.terminal(for: pane))
        #expect(terminal.activeScreen.columns == 132)
        #expect(terminal.activeScreen.rows == 43)
    }
}

private extension Array {
    /// `map` with an async transform, which the standard library does not have.
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        result.reserveCapacity(count)
        for element in self { result.append(try await transform(element)) }
        return result
    }
}
