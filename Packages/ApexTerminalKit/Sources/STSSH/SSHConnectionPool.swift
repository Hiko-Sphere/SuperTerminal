import Foundation
import NIOCore
import STCore

/// Shares one SSH transport between everything that wants the same server (D-054).
///
/// SSH already multiplexes: a single transport carries any number of channels, and a shell,
/// an SFTP subsystem, a forwarded port and a screen are all just channels. What the app was
/// doing instead was opening a whole new connection for each of them — a TCP handshake, a
/// key exchange and an authentication per tab. On a phone that is not a rounding error: it
/// is the slowest part of opening anything, it is paid again on every reconnect, and each
/// one is another chance for a server's `MaxStartups` or `MaxSessions` to say no.
///
/// **What a shared connection must never do is share the wrong thing.** Two connections that
/// differ in *who* they authenticate as, or *where* they land, are not the same connection
/// however similar they look. ``SSHConnectionIdentity`` is what decides that, and it is
/// deliberately exact rather than convenient: a different user name, a different jump chain,
/// a different credential, a different tunnel — any of those is a different pool entry. The
/// failure this prevents is the worst kind, because it would look like everything working.
public actor SSHConnectionPool {
    /// How long a connection with nothing using it stays open before it is closed.
    ///
    /// Not zero: closing the moment the last tab shuts would mean the *next* tab pays for
    /// a whole handshake again, and switching between two servers is exactly what people
    /// do. Not long either — an idle connection is one a server is holding a slot for.
    public static let idleTimeout: Duration = .seconds(30)

    private let log: STLogger
    private var entries: [SSHConnectionIdentity: Entry] = [:]

    private final class Entry {
        let connection: SSHConnection
        var users: Int
        var idleTask: Task<Void, Never>?

        init(connection: SSHConnection, users: Int) {
            self.connection = connection
            self.users = users
        }
    }

    public init(log: STLogger = .disabled) {
        self.log = log.child(subsystem: "ssh.pool")
    }

    /// A claim on a shared connection. Release it when finished.
    ///
    /// A value rather than a `deinit`-based handle on purpose: the release has to reach an
    /// actor, `deinit` cannot `await`, and a handle that released "eventually" would let a
    /// connection be closed while a later user still held it.
    public struct Lease: Sendable {
        public let connection: SSHConnection
        public let identity: SSHConnectionIdentity
    }

    /// Returns a connection for `identity`, opening one only if there is not already a
    /// live one for exactly that identity.
    ///
    /// - Parameter open: how to make one, when one is needed. Passed in rather than built
    ///   here because everything about *how* to connect — transport, credentials, host key
    ///   policy — belongs to the caller; the pool's only job is deciding whether to.
    /// `sending` because the caller's factory is usually isolated somewhere else — the
    /// app's is on the main actor — and the pool only ever calls it once, here.
    public func lease(
        identity: SSHConnectionIdentity,
        open: sending () async throws -> SSHConnection
    ) async throws -> Lease {
        if let entry = entries[identity] {
            if await entry.connection.isUsable {
                entry.idleTask?.cancel()
                entry.idleTask = nil
                entry.users += 1
                log.info("reusing a connection", ["identity": identity.diagnosticDescription, "users": "\(entry.users)"])
                return Lease(connection: entry.connection, identity: identity)
            }
            // Dead, and a dead connection in the table is worse than none: every later
            // caller would be handed a transport that cannot carry anything.
            log.info("discarding a dead pooled connection", ["identity": identity.diagnosticDescription])
            entry.idleTask?.cancel()
            entries[identity] = nil
        }

        let connection = try await open()
        // Checked again: `open` suspends, and another caller may have finished first. The
        // loser's connection is closed rather than leaked, and both callers end up on the
        // same transport, which is the whole point.
        if let existing = entries[identity], await existing.connection.isUsable {
            existing.idleTask?.cancel()
            existing.idleTask = nil
            existing.users += 1
            log.info("a second connection raced and lost; closing it", ["identity": identity.diagnosticDescription])
            await connection.close()
            return Lease(connection: existing.connection, identity: identity)
        }

        entries[identity] = Entry(connection: connection, users: 1)
        log.info("opened a connection", ["identity": identity.diagnosticDescription])
        return Lease(connection: connection, identity: identity)
    }

    /// Gives up a claim. The connection closes once nothing holds it and the idle time has
    /// passed.
    public func release(_ lease: Lease) {
        guard let entry = entries[lease.identity], entry.connection === lease.connection else { return }
        entry.users -= 1
        guard entry.users <= 0 else {
            log.debug("released", ["identity": lease.identity.diagnosticDescription, "users": "\(entry.users)"])
            return
        }
        entry.users = 0
        entry.idleTask = Task { [weak self, timeout = Self.idleTimeout] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.closeIfStillIdle(lease.identity)
        }
    }

    /// How many things are using the connection for this identity, if any. For the UI,
    /// which is where "this tab shares a connection with two others" is worth saying.
    public func users(of identity: SSHConnectionIdentity) -> Int {
        entries[identity]?.users ?? 0
    }

    /// Closes everything. Called when the app is going away, or the user asks.
    public func closeAll() async {
        let open = entries
        entries = [:]
        for (_, entry) in open {
            entry.idleTask?.cancel()
            await entry.connection.close()
        }
    }

    private func closeIfStillIdle(_ identity: SSHConnectionIdentity) async {
        guard let entry = entries[identity], entry.users <= 0 else { return }
        entries[identity] = nil
        log.info("closing an idle connection", ["identity": identity.diagnosticDescription])
        await entry.connection.close()
    }
}

/// Everything that has to match before two things may share a transport.
///
/// Exactness is the whole point. A pool keyed on the host's identifier alone would hand a
/// connection authenticated as one user to a session that asked for another — the sort of
/// mistake that produces no error at all, just a shell belonging to the wrong account. So
/// the key carries every input that decides *who* the connection is and *where* it comes
/// out: the endpoint, the user, the credentials offered, the jump chain, and the tunnel.
public struct SSHConnectionIdentity: Hashable, Sendable {
    /// The server as it is addressed, including the port.
    public let endpoint: String
    public let username: String
    /// The credentials this connection was opened with, in order. Two sessions offering
    /// different credentials are not interchangeable even against the same account: one
    /// may be about to fail, and one may carry an agent the other did not consent to.
    public let credentials: [String]
    /// The jump chain, outermost first (D-047). A connection reached through a bastion is
    /// not the same connection as a direct one, even to the same address.
    public let jumpChain: [String]
    /// The tunnel this travels through, when it is not direct.
    public let tunnel: String?
    /// Whether the connection offers this device as an SSH agent (D-052). Sharing one that
    /// does with a session that did not ask would hand a server a signing oracle nobody
    /// consented to.
    public let forwardsAgent: Bool

    public init(
        endpoint: String,
        username: String,
        credentials: [String],
        jumpChain: [String] = [],
        tunnel: String? = nil,
        forwardsAgent: Bool = false
    ) {
        self.endpoint = endpoint
        self.username = username
        self.credentials = credentials
        self.jumpChain = jumpChain
        self.tunnel = tunnel
        self.forwardsAgent = forwardsAgent
    }

    /// Safe to log: an endpoint and a user name, never a credential.
    public var diagnosticDescription: String {
        var text = "\(username)@\(endpoint)"
        if !jumpChain.isEmpty { text += " via \(jumpChain.count) hop(s)" }
        if tunnel != nil { text += " through a tunnel" }
        return text
    }
}
