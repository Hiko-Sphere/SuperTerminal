import Foundation
import NIOTransportServices
import STCore
@testable import STSSH
import STTestSupport
import Testing

/// Connection reuse, counted by the server rather than asserted (D-054).
///
/// The claim multiplexing makes is arithmetic: N sessions to one server should cost one
/// handshake, not N. `sshd` writes a line every time it accepts an authentication, so the
/// claim can be checked by reading its log instead of trusting the pool's own bookkeeping —
/// which would agree with itself whatever it did.
@Suite("Connection pooling against real OpenSSH", .serialized)
struct ConnectionPoolTests {
    /// Counts what the server actually accepted.
    private func handshakes(_ server: OpenSSHTestServer) -> Int {
        server.log().components(separatedBy: "Accepted publickey").count - 1
    }

    private func identity(_ server: OpenSSHTestServer) -> SSHConnectionIdentity {
        SSHConnectionIdentity(
            endpoint: "127.0.0.1:\(server.fixtures.port)",
            username: server.fixtures.username,
            credentials: ["key"]
        )
    }

    @Test("Four sessions to one server cost one handshake, not four")
    func reuseCostsOneHandshake() async throws {
        let server = try OpenSSHTestServer()
        defer { server.shutDown() }
        let pool = SSHConnectionPool()
        let key = identity(server)

        var leases: [SSHConnectionPool.Lease] = []
        for _ in 0 ..< 4 {
            leases.append(try await pool.lease(identity: key) { try await connect(to: server) })
        }

        // Every lease is the same transport, and each one can still open a channel of its
        // own: reuse that could not carry concurrent work would not be reuse.
        #expect(await pool.users(of: key) == 4)
        for lease in leases {
            let result = try await lease.connection.execute(command: "printf POOL_OK")
            #expect(result.standardOutputText == "POOL_OK")
        }

        #expect(handshakes(server) == 1, "the server accepted \(handshakes(server)) authentications:\n\(server.log())")

        for lease in leases { await pool.release(lease) }
        await pool.closeAll()
    }

    @Test("A different user name is a different connection, however similar it looks")
    func differentIdentitiesAreNotShared() async throws {
        let server = try OpenSSHTestServer()
        defer { server.shutDown() }
        let pool = SSHConnectionPool()

        let mine = identity(server)
        var somebodyElse = SSHConnectionIdentity(
            endpoint: mine.endpoint,
            username: "somebody-else",
            credentials: mine.credentials
        )

        let first = try await pool.lease(identity: mine) { try await connect(to: server) }
        // The second identity must open its own connection. If the pool handed back the
        // first, this would silently be a shell belonging to the wrong account — the one
        // failure mode that produces no error at all.
        let second = try await pool.lease(identity: somebodyElse) { try await connect(to: server) }
        #expect(first.connection !== second.connection)
        #expect(await pool.users(of: mine) == 1)
        #expect(await pool.users(of: somebodyElse) == 1)

        somebodyElse = mine
        await pool.closeAll()
    }

    @Test("Every part of the identity is part of the key")
    func identityDistinguishesEverythingThatMatters() {
        let base = SSHConnectionIdentity(endpoint: "a:22", username: "u", credentials: ["k"])
        let variants: [(String, SSHConnectionIdentity)] = [
            ("endpoint", .init(endpoint: "b:22", username: "u", credentials: ["k"])),
            ("port", .init(endpoint: "a:2222", username: "u", credentials: ["k"])),
            ("username", .init(endpoint: "a:22", username: "other", credentials: ["k"])),
            ("credentials", .init(endpoint: "a:22", username: "u", credentials: ["other"])),
            ("jump chain", .init(endpoint: "a:22", username: "u", credentials: ["k"], jumpChain: ["bastion"])),
            ("tunnel", .init(endpoint: "a:22", username: "u", credentials: ["k"], tunnel: "cf")),
            ("agent", .init(endpoint: "a:22", username: "u", credentials: ["k"], forwardsAgent: true)),
        ]
        for (what, variant) in variants {
            #expect(variant != base, "a different \(what) must not share a connection")
            #expect(variant.hashValue != base.hashValue || variant != base)
        }
        // And the same inputs must match, or nothing would ever be reused.
        #expect(SSHConnectionIdentity(endpoint: "a:22", username: "u", credentials: ["k"]) == base)
    }

    @Test("One channel failing leaves the others working")
    func oneChannelFailingDoesNotTakeDownTheRest() async throws {
        let server = try OpenSSHTestServer()
        defer { server.shutDown() }
        let pool = SSHConnectionPool()
        let key = identity(server)

        let lease = try await pool.lease(identity: key) { try await connect(to: server) }
        let second = try await pool.lease(identity: key) { try await connect(to: server) }

        // A command that fails is still a channel that closed badly. The transport must
        // not care: channel lifetimes are independent, and a tab whose command failed
        // must not take the other tabs with it.
        let failed = try await lease.connection.execute(command: "exit 7")
        #expect(failed.exitStatus == 7)

        let after = try await second.connection.execute(command: "printf STILL_HERE")
        #expect(after.standardOutputText == "STILL_HERE")
        #expect(handshakes(server) == 1)

        await pool.release(lease)
        await pool.release(second)
        await pool.closeAll()
    }

    @Test("A dead connection is replaced rather than handed out again")
    func deadConnectionsAreDiscarded() async throws {
        let server = try OpenSSHTestServer()
        defer { server.shutDown() }
        let pool = SSHConnectionPool()
        let key = identity(server)

        let first = try await pool.lease(identity: key) { try await connect(to: server) }
        // Close the transport underneath the pool, the way a network drop would.
        await first.connection.close()
        #expect(await first.connection.isUsable == false)

        let second = try await pool.lease(identity: key) { try await connect(to: server) }
        #expect(second.connection !== first.connection)
        let result = try await second.connection.execute(command: "printf REPLACED")
        #expect(result.standardOutputText == "REPLACED")
        // Two handshakes, correctly: the first connection really was gone.
        #expect(handshakes(server) == 2)

        await pool.release(second)
        await pool.closeAll()
    }

    @Test("The last release closes the connection; an earlier one does not")
    func refcountingKeepsTheConnectionUntilNobodyWantsIt() async throws {
        let server = try OpenSSHTestServer()
        defer { server.shutDown() }
        let pool = SSHConnectionPool()
        let key = identity(server)

        let first = try await pool.lease(identity: key) { try await connect(to: server) }
        let second = try await pool.lease(identity: key) { try await connect(to: server) }

        await pool.release(first)
        // Still one user: closing here would have broken a session that never asked to end.
        #expect(await pool.users(of: key) == 1)
        let stillWorks = try await second.connection.execute(command: "printf ALIVE")
        #expect(stillWorks.standardOutputText == "ALIVE")

        await pool.release(second)
        #expect(await pool.users(of: key) == 0)
        // The connection is not closed *yet* — the idle timeout has not elapsed — which is
        // what makes reopening a tab cheap.
        #expect(await second.connection.isUsable)

        await pool.closeAll()
        #expect(await second.connection.isUsable == false)
    }

    @Test("A session opened after the last one closed reuses the still-idle connection")
    func anIdleConnectionIsReusedBeforeItExpires() async throws {
        let server = try OpenSSHTestServer()
        defer { server.shutDown() }
        let pool = SSHConnectionPool()
        let key = identity(server)

        let first = try await pool.lease(identity: key) { try await connect(to: server) }
        await pool.release(first)

        // Well inside the idle timeout: this is the "close a tab, open another" case, and
        // paying for a second handshake there is exactly what pooling is for.
        let second = try await pool.lease(identity: key) { try await connect(to: server) }
        #expect(second.connection === first.connection)
        #expect(handshakes(server) == 1)

        await pool.release(second)
        await pool.closeAll()
    }

    /// Measures what reuse is worth here, rather than asserting that it is worth something.
    ///
    /// Not an assertion on the numbers: they belong to this machine and this loopback, and
    /// a test that failed when a laptop was busy would teach nothing. It prints, and the
    /// figures go in `docs/RELEASE_EVIDENCE.md`.
    @Test("Measure: what four sessions cost with and without a shared transport")
    func measureTheSaving() async throws {
        let server = try OpenSSHTestServer()
        defer { server.shutDown() }
        let key = identity(server)

        var separate: [SSHConnection] = []
        let withoutStart = ContinuousClock.now
        for _ in 0 ..< 4 { separate.append(try await connect(to: server)) }
        let without = ContinuousClock.now - withoutStart
        for connection in separate { await connection.close() }
        let handshakesWithout = handshakes(server)

        let pool = SSHConnectionPool()
        let withStart = ContinuousClock.now
        var leases: [SSHConnectionPool.Lease] = []
        for _ in 0 ..< 4 {
            leases.append(try await pool.lease(identity: key) { try await connect(to: server) })
        }
        let with = ContinuousClock.now - withStart
        let handshakesTotal = handshakes(server)
        for lease in leases { await pool.release(lease) }
        await pool.closeAll()

        print("POOL_MEASUREMENT four sessions: separate \(without) / \(handshakesWithout) handshakes; "
            + "shared \(with) / \(handshakesTotal - handshakesWithout) handshakes")
        #expect(handshakesTotal - handshakesWithout == 1)
    }

    private func connect(to server: OpenSSHTestServer) async throws -> SSHConnection {
        let identity = KnownHostIdentity(host: "127.0.0.1", port: server.fixtures.port)
        return try await SSHConnection.connect(
            transport: DirectTCPTransport(endpoint: TransportEndpoint(host: "127.0.0.1", port: server.fixtures.port)),
            configuration: SSHConnectionConfiguration(
                username: server.fixtures.username,
                credentials: [.privateKey(try OpenSSHPrivateKeyParser.parse(pem: server.fixtures.clientPrivateKeyPEM))],
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
}
