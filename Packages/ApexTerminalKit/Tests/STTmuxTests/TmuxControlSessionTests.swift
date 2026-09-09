import Foundation
import Testing

@testable import STTmux

/// The command/notification bookkeeping, against a transport that records what was written
/// and can be fed whatever tmux would have replied.
///
/// This is the one place a fake is right: what is under test is the client's own
/// bookkeeping — which reply belongs to which command — and a real server would make the
/// interesting cases (a reply arriving before its command's, a session ending mid-command)
/// hard to produce on purpose. The protocol itself is verified against a real tmux in
/// `TmuxIntegrationTests`.
private final class RecordingTransport: TmuxControlTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var written: [String] = []
    var failNextWrite: Error?

    func write(_ bytes: [UInt8]) async throws {
        if let error = failNextWrite {
            failNextWrite = nil
            throw error
        }
        lock.withLock { written.append(String(decoding: bytes, as: UTF8.self)) }
    }

    var lines: [String] { lock.withLock { written } }
}

@Suite("tmux control session")
struct TmuxControlSessionTests {
    @Test("A command's reply is the lines between the guards")
    func repliesAreMatched() async throws {
        let transport = RecordingTransport()
        let session = TmuxControlSession(transport: transport)

        async let reply = session.send("list-windows")
        // Wait until the command is actually on the wire before answering it, rather than
        // guessing with a sleep.
        while transport.lines.isEmpty { await Task.yield() }
        await session.receive(Array("""
        %begin 1 265 1
        0: bash* (1 panes) [80x24] @0 (active)
        %end 1 265 1

        """.utf8))

        #expect(try await reply == ["0: bash* (1 panes) [80x24] @0 (active)"])
        #expect(transport.lines == ["list-windows\n"])
    }

    @Test("A command sent before the attach block still gets its own reply")
    func theAttachBlockDoesNotStealAReply() async throws {
        // The case a real server found. Sending immediately means the command *is* waiting
        // when the attach block arrives, so "drop a block when nothing is waiting" claimed
        // it and every reply after that was one out of step. tmux marks a reply in the
        // flags field — 1 for a client's command, 0 for the attach block — and that is what
        // tells them apart.
        let transport = RecordingTransport()
        let session = TmuxControlSession(transport: transport)

        let reply = Task { try await session.send("display-message -p ORDERING_PROBE") }
        while transport.lines.isEmpty { await Task.yield() }
        await session.receive(Array("""
        %begin 1 259 0
        %end 1 259 0
        %begin 1 265 1
        ORDERING_PROBE
        %end 1 265 1

        """.utf8))
        #expect(try await reply.value == ["ORDERING_PROBE"])
    }

    @Test("The block tmux sends before any command is not mistaken for a reply")
    func theAttachBlockIsNotAReply() async throws {
        // Measured against a real server: attaching produces `%begin 259`/`%end 259` before
        // the client has sent anything. A queue that assumed every block belongs to a
        // command would answer the first command with this and stay one reply out of step
        // for the whole session.
        let transport = RecordingTransport()
        let session = TmuxControlSession(transport: transport)
        await session.receive(Array("%begin 1 259 0\n%end 1 259 0\n".utf8))

        async let reply = session.send("display-message -p '#{pane_id}'")
        while transport.lines.isEmpty { await Task.yield() }
        await session.receive(Array("%begin 2 265 1\n%0\n%end 2 265 1\n".utf8))
        #expect(try await reply == ["%0"])
    }

    @Test("A refused command throws with what tmux said")
    func errorsAreThrown() async throws {
        let transport = RecordingTransport()
        let session = TmuxControlSession(transport: transport)

        let reply = Task { try await session.send("not-a-command") }
        while transport.lines.isEmpty { await Task.yield() }
        await session.receive(Array("""
        %begin 1 265 1
        parse error: unknown command: not-a-command
        %error 1 265 1

        """.utf8))

        await #expect(throws: TmuxError.commandFailed(
            command: "not-a-command",
            message: "parse error: unknown command: not-a-command"
        )) {
            _ = try await reply.value
        }
    }

    @Test("Notifications arrive on the stream, in order")
    func notificationsAreStreamed() async throws {
        let transport = RecordingTransport()
        let session = TmuxControlSession(transport: transport)
        let stream = session.notifications

        await session.receive(Array("""
        %window-add @0
        %session-changed $0 main
        %output %0 hi
        %exit

        """.utf8))

        var received: [TmuxNotification] = []
        for await notification in stream { received.append(notification) }
        #expect(received == [
            .windowAdd(window: TmuxWindowID(0)),
            .sessionChanged(session: TmuxSessionID(0), name: "main"),
            .output(pane: TmuxPaneID(0), bytes: Array("hi".utf8)),
            .exit(reason: nil),
        ])
    }

    @Test("A session that ends fails what was waiting rather than hanging")
    func endingFailsPendingCommands() async throws {
        let transport = RecordingTransport()
        let session = TmuxControlSession(transport: transport)

        let reply = Task { try await session.send("list-windows") }
        while transport.lines.isEmpty { await Task.yield() }
        await session.receive(Array("%exit server exited unexpectedly\n".utf8))

        await #expect(throws: TmuxError.sessionEnded(reason: "server exited unexpectedly")) {
            _ = try await reply.value
        }
        // And nothing more can be sent, rather than waiting for a reply that cannot come.
        await #expect(throws: TmuxError.sessionEnded(reason: "server exited unexpectedly")) {
            _ = try await session.send("list-windows")
        }
    }

    @Test("A write that fails fails its command")
    func writeFailuresSurface() async throws {
        struct Broken: Error, Equatable {}
        let transport = RecordingTransport()
        transport.failNextWrite = Broken()
        let session = TmuxControlSession(transport: transport)
        await #expect(throws: Broken.self) { _ = try await session.send("list-windows") }
    }
}
