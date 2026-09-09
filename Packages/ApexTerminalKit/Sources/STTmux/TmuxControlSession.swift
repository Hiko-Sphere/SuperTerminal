import Foundation
import STCore

/// Somewhere to write the commands a control session sends.
///
/// A protocol rather than an SSH channel so the protocol can be exercised against a tmux
/// running anywhere — a pipe, a container, a real server — and so this module does not
/// depend on the SSH one.
public protocol TmuxControlTransport: Sendable {
    func write(_ bytes: [UInt8]) async throws
}

public enum TmuxError: Error, LocalizedError, Equatable {
    /// The command tmux refused, and what it said about it. tmux puts the message in the
    /// block *before* `%error`, which is why it can be reported at all.
    case commandFailed(command: String, message: String)
    case sessionEnded(reason: String?)

    public var errorDescription: String? {
        switch self {
        case let .commandFailed(command, message):
            String(localized: "tmux refused ‘\(command)’: \(message)", bundle: .module)
        case let .sessionEnded(reason):
            if let reason {
                String(localized: "The tmux session ended: \(reason)", bundle: .module)
            } else {
                String(localized: "The tmux session ended.", bundle: .module)
            }
        }
    }
}

/// A tmux control-mode client.
///
/// Two things happen on one stream and both have to be kept straight: replies to commands
/// this client sent, and notifications the server sends on its own. tmux replies in the
/// order it was asked, so a queue of continuations is enough — no request ids, because the
/// protocol has none.
///
/// One detail that only shows up against a real server: tmux emits a `%begin`/`%end` pair
/// **before any command is sent**, as the client attaches. A queue that assumed every block
/// belongs to a command would answer the first real command with the attach block's empty
/// output and then be one reply out of step for the rest of the session — the kind of fault
/// that looks like tmux being slow.
///
/// "Drop a block when nothing is waiting" is not enough, and a test against a real server is
/// what proved it: a command sent immediately on attaching *is* waiting when the attach
/// block arrives, and claimed it. What actually separates them is the flags field —
/// measured on tmux 3.3a, every reply to a client's command carries `1` and the attach block
/// carries `0` — so that is what is used, with the empty queue as a second line of defence.
public actor TmuxControlSession {
    private let transport: TmuxControlTransport
    private let log: STLogger
    private var parser = TmuxControlParser()

    private struct PendingCommand {
        let command: String
        let continuation: CheckedContinuation<[String], Error>
    }

    private var pending: [PendingCommand] = []
    private var collecting: [String]?
    private var isCollectingForACommand = false
    private var ended: String??

    private var notificationContinuation: AsyncStream<TmuxNotification>.Continuation?
    public nonisolated let notifications: AsyncStream<TmuxNotification>

    public init(transport: TmuxControlTransport, log: STLogger = .disabled) {
        self.transport = transport
        self.log = log
        var continuation: AsyncStream<TmuxNotification>.Continuation!
        notifications = AsyncStream { continuation = $0 }
        notificationContinuation = continuation
    }

    /// Sends a command and waits for its reply, which is every line tmux wrote between
    /// `%begin` and `%end`.
    @discardableResult
    public func send(_ command: String) async throws -> [String] {
        if case let .some(reason) = ended { throw TmuxError.sessionEnded(reason: reason) }
        return try await withCheckedThrowingContinuation { continuation in
            pending.append(PendingCommand(command: command, continuation: continuation))
            // The write is its own task because the continuation must be handed back to
            // the caller before anything can resume it. The task inherits this actor's
            // isolation, so the failure path needs no hop.
            Task {
                do {
                    try await transport.write(Array((command + "\n").utf8))
                } catch {
                    self.failFirstPending(with: error)
                }
            }
        }
    }

    /// Feeds in whatever arrived from the far end.
    public func receive(_ bytes: [UInt8]) {
        let messages: [TmuxControlMessage]
        do {
            messages = try parser.consume(bytes)
        } catch {
            log.error("the tmux control stream could not be parsed", ["error": String(describing: error)])
            finish(reason: nil)
            return
        }
        for message in messages { handle(message) }
    }

    /// The far end is gone: every waiting command fails rather than hanging, which is the
    /// difference between a session that reports a broken connection and one that appears
    /// to work until someone gives up.
    public func finish(reason: String?) {
        guard ended == nil else { return }
        ended = .some(reason)
        let waiting = pending
        pending.removeAll()
        for item in waiting {
            item.continuation.resume(throwing: TmuxError.sessionEnded(reason: reason))
        }
        notificationContinuation?.finish()
        notificationContinuation = nil
    }

    private func failFirstPending(with error: Error) {
        guard !pending.isEmpty else { return }
        let item = pending.removeFirst()
        item.continuation.resume(throwing: error)
    }

    private func handle(_ message: TmuxControlMessage) {
        switch message {
        case let .commandBegin(_, _, flags):
            collecting = []
            let isAReply = flags & 1 != 0
            isCollectingForACommand = isAReply && !pending.isEmpty
            if !isAReply {
                log.debug("a tmux block that is not a reply to a command")
            } else if pending.isEmpty {
                log.debug("a tmux command block arrived with nothing waiting for it")
            }
        case let .commandOutput(line):
            if collecting != nil {
                collecting?.append(line)
            } else {
                // Outside a block, and not a notification: the far end is saying something
                // that is not the protocol — a login banner, most often.
                    // Not logged verbatim: a banner is the far end's text, and this
                // module has no way to know what a server chose to print in it.
                log.info("unexpected line from tmux", ["bytes": "\(line.utf8.count)"])
            }
        case let .commandEnd(_, failed):
            let lines = collecting ?? []
            collecting = nil
            guard isCollectingForACommand, !pending.isEmpty else {
                isCollectingForACommand = false
                return
            }
            isCollectingForACommand = false
            let item = pending.removeFirst()
            if failed {
                item.continuation.resume(
                    throwing: TmuxError.commandFailed(
                        command: item.command,
                        message: lines.joined(separator: "\n")
                    )
                )
            } else {
                item.continuation.resume(returning: lines)
            }
        case let .notification(notification):
            if case let .exit(reason) = notification {
                notificationContinuation?.yield(notification)
                finish(reason: reason)
                return
            }
            notificationContinuation?.yield(notification)
        }
    }
}
