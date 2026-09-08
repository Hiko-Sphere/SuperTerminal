import Foundation

/// One port-forwarding rule, saved with the connection it belongs to (D-045).
///
/// A rule is a thing the user names, edits and keeps — not a command-line flag typed
/// again every session. It carries no secret and nothing session-specific: two devices can
/// hold the same rule, and it means the same thing on both.
public struct PortForward: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    /// What the user calls it. May be empty, in which case the interface shows the
    /// addresses instead — a rule is allowed to be self-explanatory.
    public var name: String
    public var kind: Kind
    /// For a local or dynamic forward, the port on this device. For a remote forward, the
    /// port the *server* is asked to listen on. Zero means "any free port", which the
    /// protocol supports for remote forwards and which the server then reports back.
    public var listenPort: Int
    /// Where the traffic ends up. Resolved by the server for a local forward, by this
    /// device for a remote one, and by neither for a dynamic one — SOCKS clients name
    /// their own destination.
    public var targetHost: String
    public var targetPort: Int
    /// The address the server binds for a remote forward. `127.0.0.1` keeps it reachable
    /// only from the server itself; anything wider needs `GatewayPorts` in its sshd, and
    /// the interface says so rather than letting the request fail unexplained.
    public var remoteBindHost: String
    /// Whether opening the connection should start this rule.
    public var startsAutomatically: Bool

    public init(
        id: UUID = UUID(),
        name: String = "",
        kind: Kind,
        listenPort: Int,
        targetHost: String = "",
        targetPort: Int = 0,
        remoteBindHost: String = "127.0.0.1",
        startsAutomatically: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.listenPort = listenPort
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.remoteBindHost = remoteBindHost
        self.startsAutomatically = startsAutomatically
    }

    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
        /// `ssh -L`: this device listens, the server connects onwards.
        case local
        /// `ssh -R`: the server listens, this device connects onwards.
        case remote
        /// `ssh -D`: this device listens as a SOCKS5 proxy and the server connects to
        /// wherever each client asks for.
        case dynamic
    }

    /// What is wrong with the rule, in the words the editor shows.
    ///
    /// Ports are checked here rather than at start time because a rule that cannot work
    /// should not be saveable — finding out at connection time, three screens away, is how
    /// a typo becomes a mystery.
    public var validationProblems: [String] {
        var problems: [String] = []
        let listenRange = kind == .remote ? 0 ... 65535 : 1 ... 65535
        if !listenRange.contains(listenPort) {
            problems.append(kind == .remote
                ? String(localized: "The port the server listens on must be between 0 and 65535. Zero asks it to choose one.", bundle: .module)
                : String(localized: "The port on this device must be between 1 and 65535.", bundle: .module))
        }
        if kind != .dynamic {
            if targetHost.trimmingCharacters(in: .whitespaces).isEmpty {
                problems.append(String(localized: "Enter the address the traffic should be forwarded to.", bundle: .module))
            }
            if !(1 ... 65535).contains(targetPort) {
                problems.append(String(localized: "The destination port must be between 1 and 65535.", bundle: .module))
            }
        }
        return problems
    }

    /// The one-line description shown when a rule has no name.
    public var addressSummary: String {
        switch kind {
        case .local: "127.0.0.1:\(listenPort) → \(targetHost):\(targetPort)"
        case .remote: "\(remoteBindHost):\(listenPort) → \(targetHost):\(targetPort)"
        case .dynamic: "SOCKS5 127.0.0.1:\(listenPort)"
        }
    }

    public var displayName: String {
        name.trimmingCharacters(in: .whitespaces).isEmpty ? addressSummary : name
    }
}

/// What a rule is doing right now. Not persisted: a forward exists only while the
/// connection carrying it does.
public enum PortForwardState: Sendable, Equatable {
    case stopped
    case starting
    /// Running, on the port that was actually bound — which is not always the one asked
    /// for, because a remote forward may ask the server to choose.
    case running(port: Int)
    /// Stopped because something went wrong, with the sentence to show.
    case failed(message: String, recovery: String?)

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

/// Traffic through one rule, for the indicator in the interface.
public struct PortForwardTraffic: Sendable, Equatable {
    public var bytesOut: Int = 0
    public var bytesIn: Int = 0
    /// Connections currently open through the rule.
    public var openConnections: Int = 0
    /// Connections it has carried since it started.
    public var totalConnections: Int = 0

    public init() {}
}
