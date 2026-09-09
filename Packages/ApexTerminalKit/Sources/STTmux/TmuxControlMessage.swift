import Foundation

/// tmux's own identifiers, kept apart so a window id cannot be passed where a pane id
/// belongs. tmux writes them with a sigil — `%0` for a pane, `@0` for a window, `$0` for a
/// session — and the sigil is part of what it prints back, so it is kept.
public struct TmuxPaneID: Hashable, Sendable, CustomStringConvertible {
    public let number: Int
    public init(_ number: Int) { self.number = number }
    public var description: String { "%\(number)" }
}

public struct TmuxWindowID: Hashable, Sendable, CustomStringConvertible {
    public let number: Int
    public init(_ number: Int) { self.number = number }
    public var description: String { "@\(number)" }
}

public struct TmuxSessionID: Hashable, Sendable, CustomStringConvertible {
    public let number: Int
    public init(_ number: Int) { self.number = number }
    public var description: String { "$\(number)" }
}

/// One thing tmux said in control mode.
///
/// Control mode is line-based: every line either belongs to a command's reply, between
/// `%begin` and `%end`/`%error`, or is a notification beginning with `%`. That is the whole
/// framing, and it is why this type has exactly these four cases.
public enum TmuxControlMessage: Equatable, Sendable {
    /// `%begin <time> <number> <flags>`
    case commandBegin(number: Int, time: Int, flags: Int)
    /// A line of a command's reply, verbatim.
    case commandOutput(String)
    /// `%end` or `%error`, which are the same frame with different meanings.
    case commandEnd(number: Int, failed: Bool)
    case notification(TmuxNotification)
}

/// Everything tmux announces without being asked.
///
/// The cases here were taken from a running tmux 3.3a rather than from the manual: each one
/// below was produced by driving a real server and reading what came back, which is also
/// where the shapes that documentation gets wrong were settled — `%error` closes a block
/// whose body holds the message, `%extended-output` puts an age and a literal `:` before the
/// data, and output bytes are escaped in octal *including the backslash itself* (`\134`),
/// so a raw backslash never appears and UTF-8 passes through untouched.
public enum TmuxNotification: Equatable, Sendable {
    case output(pane: TmuxPaneID, bytes: [UInt8])
    /// `%extended-output <pane> <age> : <data>` — what `%output` becomes once the client
    /// has asked for `pause-after`.
    case extendedOutput(pane: TmuxPaneID, age: Int, bytes: [UInt8])

    case windowAdd(window: TmuxWindowID)
    case windowClose(window: TmuxWindowID)
    case windowRenamed(window: TmuxWindowID, name: String)
    case windowPaneChanged(window: TmuxWindowID, pane: TmuxPaneID)
    case unlinkedWindowAdd(window: TmuxWindowID)
    case unlinkedWindowClose(window: TmuxWindowID)
    case unlinkedWindowRenamed(window: TmuxWindowID, name: String)

    case sessionsChanged
    case sessionChanged(session: TmuxSessionID, name: String)
    case sessionRenamed(name: String)
    case sessionWindowChanged(session: TmuxSessionID, window: TmuxWindowID)

    case layoutChange(window: TmuxWindowID, layout: String, visibleLayout: String, flags: String)

    case clientDetached(client: String)
    case clientSessionChanged(client: String, session: TmuxSessionID, name: String)

    case paneModeChanged(pane: TmuxPaneID)
    case pause(pane: TmuxPaneID)
    case resume(pane: TmuxPaneID)

    case subscriptionChanged(name: String, rest: String)
    case message(String)
    case exit(reason: String?)

    /// A notification this version does not model. Kept rather than dropped: tmux adds
    /// them between releases, and a client that silently discards what it does not know
    /// cannot be debugged by anyone reading a log.
    case unrecognised(name: String, arguments: String)
}
