import Foundation
import NIOSSH
import NIOTransportServices
import STCore
import STTestSupport
import Testing

@testable import STSSH

/// Jumping through one real SSH server to reach another (D-047).
///
/// Two separate `sshd` processes, each with its own host key and its own authorized keys.
/// The test proves the inner connection really is the second server by reading back the
/// host key it recorded and comparing it with what the second server published — a
/// connection that had quietly stayed on the bastion would fail that comparison.
@Suite("Jump hosts against real OpenSSH", .serialized)
struct JumpHostTests {
    private func connect(
        to server: OpenSSHTestServer,
        store: any KnownHostsStore = InMemoryKnownHostsStore(),
        through carrier: SSHConnection? = nil
    ) async throws -> SSHConnection {
        let identity = KnownHostIdentity(host: "127.0.0.1", port: server.fixtures.port)
        let transport: any ByteStreamTransport = if let carrier {
            JumpTransport(
                through: carrier,
                to: TransportEndpoint(host: "127.0.0.1", port: server.fixtures.port),
                carrierDescription: "bastion"
            )
        } else {
            DirectTCPTransport(endpoint: TransportEndpoint(host: "127.0.0.1", port: server.fixtures.port))
        }
        return try await SSHConnection.connect(
            transport: transport,
            configuration: SSHConnectionConfiguration(
                username: server.fixtures.username,
                credentials: [.privateKey(try OpenSSHPrivateKeyParser.parse(pem: server.fixtures.clientPrivateKeyPEM))],
                knownHostIdentity: identity
            ),
            hostKeyVerifier: HostKeyVerifier(identity: identity, store: store, approval: TrustOnFirstUseApproval()),
            eventLoop: NIOTSEventLoopGroup.singleton.next()
        )
    }

    @Test("A command runs on the far server, reached through a bastion")
    func jumpReachesTheFarServer() async throws {
        let bastion = try OpenSSHTestServer()
        defer { bastion.shutDown() }
        let destination = try OpenSSHTestServer()
        defer { destination.shutDown() }
        #expect(bastion.fixtures.port != destination.fixtures.port)

        let carrier = try await connect(to: bastion)
        let store = InMemoryKnownHostsStore()
        let inner = try await connect(to: destination, store: store, through: carrier)
        await inner.adopt(carrier: carrier)

        let result = try await inner.execute(command: "printf JUMPED")
        #expect(result.standardOutputText == "JUMPED")

        // The host key the inner connection checked is the *destination's*, which is the
        // only thing that distinguishes "reached the far server" from "never left the
        // bastion" when both are on the same loopback.
        let identity = KnownHostIdentity(host: "127.0.0.1", port: destination.fixtures.port)
        let recorded = try #require(try await store.entry(for: identity))
        let expected = try SSHHostKey(NIOSSHPublicKey(openSSHPublicKey: destination.fixtures.hostKeyOpenSSH))
        #expect(recorded.key.fingerprintSHA256 == expected.fingerprintSHA256)

        let bastionKey = try SSHHostKey(NIOSSHPublicKey(openSSHPublicKey: bastion.fixtures.hostKeyOpenSSH))
        #expect(recorded.key.fingerprintSHA256 != bastionKey.fingerprintSHA256)

        await inner.close()
    }

    @Test("Closing the connection closes the bastion behind it")
    func closingCascades() async throws {
        let bastion = try OpenSSHTestServer()
        defer { bastion.shutDown() }
        let destination = try OpenSSHTestServer()
        defer { destination.shutDown() }

        let carrier = try await connect(to: bastion)
        let inner = try await connect(to: destination, through: carrier)
        await inner.adopt(carrier: carrier)

        await inner.close()
        // A bastion left open after the session it existed for is how a jump host with a
        // session limit locks somebody out.
        try await withTimeout(seconds: 10) { await carrier.waitUntilClosed() }
    }

    @Test("A session whose bastion connection drops ends, rather than looking alive")
    func losingTheBastionEndsTheSession() async throws {
        let bastion = try OpenSSHTestServer()
        defer { bastion.shutDown() }
        let destination = try OpenSSHTestServer()
        defer { destination.shutDown() }

        let carrier = try await connect(to: bastion)
        let inner = try await connect(to: destination, through: carrier)
        await inner.adopt(carrier: carrier)
        #expect(try await inner.execute(command: "printf UP").standardOutputText == "UP")

        // The bastion's *connection* is what carries the session, so that is what is
        // dropped here. Killing the server's listening process would not do it: sshd
        // forks a child for each connection, and an established session survives its
        // parent — which is a fact about sshd, not about the client, and a test that
        // relied on it would be testing the wrong thing.
        await carrier.close()

        // The inner session travels inside that connection and cannot outlive it. What
        // matters is that it does not appear to: a terminal that accepts typing into a
        // tunnel that no longer exists is worse than one that says it has gone.
        try await withTimeout(seconds: 15) { await inner.waitUntilClosed() }
    }

    @Test("Each hop is checked against its own record, so a bastion cannot stand in for the destination")
    func hostKeysAreSeparate() async throws {
        let bastion = try OpenSSHTestServer()
        defer { bastion.shutDown() }
        let destination = try OpenSSHTestServer()
        defer { destination.shutDown() }

        let store = InMemoryKnownHostsStore()
        let carrier = try await connect(to: bastion, store: store)
        let inner = try await connect(to: destination, store: store, through: carrier)
        await inner.adopt(carrier: carrier)

        // Two entries, two identities, two keys: the store has no way to confuse them,
        // which is what makes a jump chain safe rather than a single trust decision.
        let entries = try await store.all()
        #expect(entries.count == 2)
        #expect(Set(entries.map(\.identity.port)) == [bastion.fixtures.port, destination.fixtures.port])
        #expect(Set(entries.map(\.key.fingerprintSHA256)).count == 2)

        await inner.close()
    }
}
