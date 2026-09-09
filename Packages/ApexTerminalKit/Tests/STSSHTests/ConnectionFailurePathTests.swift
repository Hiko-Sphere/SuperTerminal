import Foundation
import NIOCore
import NIOPosix
import STCore
import Testing

@testable import STSSH

/// What happens when a peer accepts and then goes away before the handshake starts (D-065).
///
/// This is not a rare shape: a health-check port, a load balancer with no backend behind it,
/// a server being restarted underneath a retry. The connection has been made, so `connect`
/// is past the point where a transport error is thrown, and the pipeline cannot be built.
@Suite("Connections that die before the handshake")
struct ConnectionFailurePathTests {
    /// Hands back a real channel that is already closed, which is what makes this
    /// deterministic: installing handlers on it fails every time rather than when the timing
    /// happens to line up.
    struct ClosedChannelTransport: ByteStreamTransport {
        let group: EventLoopGroup
        var transportDescription: String { "test://closed" }

        func connect(on eventLoop: EventLoop) async throws -> Channel {
            // A listener that accepts and immediately closes, so the client channel below is
            // a real socket channel rather than an embedded one.
            let server = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { $0.close() }
                .bind(host: "127.0.0.1", port: 0)
                .get()
            defer { _ = server.close() }
            let channel = try await ClientBootstrap(group: group)
                .connect(host: "127.0.0.1", port: server.localAddress!.port!)
                .get()
            try await channel.close().get()
            return channel
        }
    }

    @Test("It fails with a reason rather than leaving a promise nobody will ever complete",
          .timeLimit(.minutes(1)))
    func failsWithoutLeakingAPromise() async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let identity = KnownHostIdentity(host: "127.0.0.1", port: 22)
        let configuration = SSHConnectionConfiguration(
            username: "nobody",
            credentials: [],
            knownHostIdentity: identity
        )

        // Ten attempts, because the bug this pins was a NIO precondition in
        // `EventLoopFuture.deinit`: the promise made before the pipeline was built was never
        // completed on this path, and a debug build traps when it is deallocated. One
        // attempt would leave it to chance whether the deallocation happened inside the test.
        for _ in 0 ..< 10 {
            await #expect(throws: STError.self) {
                _ = try await SSHConnection.connect(
                    transport: ClosedChannelTransport(group: group),
                    configuration: configuration,
                    hostKeyVerifier: HostKeyVerifier(
                        identity: identity,
                        store: InMemoryKnownHostsStore(),
                        approval: TrustOnFirstUseApproval()
                    ),
                    eventLoop: group.next()
                )
            }
        }
    }
}
