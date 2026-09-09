import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import NIOTransportServices
import STCore
import STTestSupport
import Testing

@testable import STSSH

/// What a server may and may not open towards this device (D-060).
///
/// The User Notice makes two promises about this: a forwarded connection arrives only
/// where a forward was asked for, and the agent answers only where agent forwarding was
/// turned on for that connection. Both are claims about what the client *refuses*, and a
/// refusal can only be tested by something that tries — so these run against a server
/// written to misbehave.
@Suite("Channels a server opens towards the device", .serialized)
struct InboundChannelRefusalTests {
    private func connect(to server: HostileSSHTestServer) async throws -> SSHConnection {
        let identity = KnownHostIdentity(host: "127.0.0.1", port: server.port)
        return try await SSHConnection.connect(
            transport: DirectTCPTransport(
                endpoint: TransportEndpoint(host: "127.0.0.1", port: server.port)
            ),
            configuration: SSHConnectionConfiguration(
                username: server.username,
                credentials: [.password(Redacted(server.password, label: "ssh-password"))],
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

    @Test("A forwarded connection for a port nobody asked to forward is refused",
          .timeLimit(.minutes(1)))
    func refusesUnrequestedForward() async throws {
        let server = try HostileSSHTestServer(transportProtectionSchemes: SSHConnection.transportProtectionSchemes)
        defer { server.shutDown() }
        let connection = try await connect(to: server)
        defer { Task { await connection.close() } }

        let accepted = try server.openUnrequestedChannel(.forwardedTCPIP(.init(
            listeningHost: "127.0.0.1",
            listeningPort: 9,
            originatorAddress: try SocketAddress(ipAddress: "127.0.0.1", port: 1234)
        )))
        #expect(!accepted, "a forward nobody asked for must not be accepted")
        // And refusing it must not take the session with it: a client that dropped the
        // connection every time a server tried this would be denial-of-service by design.
        #expect(server.isConnectionAlive, "the session should survive the refusal")
    }

    @Test("An agent channel is refused when agent forwarding was never offered",
          .timeLimit(.minutes(1)))
    func refusesAgentChannelWithoutAgent() async throws {
        // The connection is made with no agent, which is the default and what the notice
        // promises: "programs on the server cannot use your key".
        let server = try HostileSSHTestServer(transportProtectionSchemes: SSHConnection.transportProtectionSchemes)
        defer { server.shutDown() }
        let connection = try await connect(to: server)
        defer { Task { await connection.close() } }

        let accepted = try server.openUnrequestedChannel(.authAgent)
        #expect(!accepted, "an agent channel must not be answered by a connection that offers no agent")
        #expect(server.isConnectionAlive)
    }

    @Test("A forward that was asked for is accepted, and only for its own port",
          .timeLimit(.minutes(1)))
    func acceptsOnlyTheForwardThatWasAskedFor() async throws {
        // The sharpest form of the promise: asking for one port must not open the device to
        // another. A client that keyed acceptance on "some forward exists" rather than on
        // *this* address and port would pass every other test here and fail this one.
        let server = try HostileSSHTestServer(transportProtectionSchemes: SSHConnection.transportProtectionSchemes)
        defer { server.shutDown() }
        let connection = try await connect(to: server)
        defer { Task { await connection.close() } }

        let arrived = Arrivals()
        _ = try await connection.startRemoteForward(bindHost: "127.0.0.1", port: 9001) { channel, _ in
            arrived.record()
            _ = channel.close()
        }

        let wrongPort = try server.openUnrequestedChannel(.forwardedTCPIP(.init(
            listeningHost: "127.0.0.1",
            listeningPort: 9002,
            originatorAddress: try SocketAddress(ipAddress: "127.0.0.1", port: 1234)
        )))
        #expect(!wrongPort, "a channel for a port that was never forwarded must be refused")
        #expect(arrived.count == 0, "and must not reach the route that was registered")

        let rightPort = try server.openUnrequestedChannel(.forwardedTCPIP(.init(
            listeningHost: "127.0.0.1",
            listeningPort: 9001,
            originatorAddress: try SocketAddress(ipAddress: "127.0.0.1", port: 1234)
        )))
        #expect(rightPort, "the forward that was asked for must work, or the refusals prove nothing")
    }

    @Test("A session channel opened by the server is refused", .timeLimit(.minutes(1)))
    func refusesServerOpenedSession() async throws {
        // Nothing in SSH lets a server open a session on a client, and a client that
        // accepted one would be running whatever the server put in it.
        let server = try HostileSSHTestServer(transportProtectionSchemes: SSHConnection.transportProtectionSchemes)
        defer { server.shutDown() }
        let connection = try await connect(to: server)
        defer { Task { await connection.close() } }

        #expect(try !server.openUnrequestedChannel(.session))
        #expect(server.isConnectionAlive)
    }
}


/// Counts arrivals from whichever event loop delivers them.
private final class Arrivals: @unchecked Sendable {
    private let lock = NSLock()
    private var arrivals = 0

    func record() { lock.withLock { arrivals += 1 } }
    var count: Int { lock.withLock { arrivals } }
}
