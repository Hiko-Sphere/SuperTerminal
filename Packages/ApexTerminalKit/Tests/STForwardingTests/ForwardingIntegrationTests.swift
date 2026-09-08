import Foundation
import NIOCore
import NIOPosix
import NIOTransportServices
import STCore
import STSSH
import STTestSupport
import Testing

@testable import STForwarding

/// Port forwarding against OpenSSH's own server (D-045).
///
/// Every test here moves real bytes: a real listening socket on this machine, through a
/// real SSH connection, to a real service on the other side. A forward that "works" in a
/// test that never sends anything is a forward nobody has tried.
@Suite("Port forwarding against real OpenSSH", .serialized)
struct ForwardingIntegrationTests {
    /// One server for the whole suite.
    ///
    /// Nine of them, each with its own sshd, was enough extra load to push the timing of
    /// unrelated suites over their thresholds — the package's tests run several suites at
    /// once. Nothing here changes the server, so one is as good as nine, and its watchdog
    /// still cleans it up if the test process is killed.
    private static let shared: OpenSSHTestServer? = try? OpenSSHTestServer()

    private func withSession(
        _ body: (ForwardingSession, EchoServer, OpenSSHTestServer) async throws -> Void
    ) async throws {
        let server = try #require(Self.shared, "the harness sshd did not start")

        let identity = KnownHostIdentity(host: "127.0.0.1", port: server.fixtures.port)
        let connection = try await SSHConnection.connect(
            transport: DirectTCPTransport(endpoint: TransportEndpoint(host: "127.0.0.1", port: server.fixtures.port)),
            configuration: SSHConnectionConfiguration(
                username: server.fixtures.username,
                credentials: [.privateKey(try OpenSSHPrivateKeyParser.parse(pem: server.fixtures.clientPrivateKeyPEM))],
                knownHostIdentity: identity
            ),
            hostKeyVerifier: HostKeyVerifier(
                identity: identity, store: InMemoryKnownHostsStore(), approval: TrustOnFirstUseApproval()
            ),
            eventLoop: NIOTSEventLoopGroup.singleton.next()
        )

        let echo = EchoServer(group: MultiThreadedEventLoopGroup.singleton)
        try await echo.start()
        let session = ForwardingSession(connection: connection, group: NIOTSEventLoopGroup.singleton, log: .forTests)
        do {
            try await body(session, echo, server)
        } catch {
            await session.stopAll()
            await echo.stop()
            await connection.close()
            throw error
        }
        await session.stopAll()
        await echo.stop()
        await connection.close()
    }

    /// Starts a rule on a port the system picks, and reports which one it picked.
    ///
    /// Asking for a free port and then binding it a moment later is a race, and under the
    /// load of the whole package's tests it is a race that loses: the port is taken in
    /// between and the listener is refused. Binding zero has no gap — the port the
    /// listener reports is one it already holds. The editor does not offer this for a
    /// local rule, because a person needs to know which port to point their client at,
    /// but the engine has always understood it.
    private func startOnAnyPort(_ rule: PortForward, in session: ForwardingSession) async throws -> Int {
        // A port from the safe range rather than zero: an ephemeral one can be the one an
        // `OpenSSHTestServer` elsewhere in the run is about to bind. See `TestPorts`.
        var lastState: PortForwardState = .stopped
        for _ in 0 ..< 40 {
            var attempt = rule
            attempt.listenPort = Int.random(in: TestPorts.range)
            lastState = await session.start(attempt)
            if case let .running(port) = lastState { return port }
            await session.stop(rule.id)
        }
        Issue.record("the forward did not start: \(lastState)")
        throw ForwardDidNotStart()
    }

    private struct ForwardDidNotStart: Error {}

    // MARK: - Local forwarding

    @Test("A local forward carries bytes to a service on the other side")
    func localForwardCarriesBytes() async throws {
        try await withSession { session, echo, _ in
            let rule = PortForward(
                name: "echo", kind: .local, listenPort: 0,
                targetHost: "127.0.0.1", targetPort: echo.port
            )
            let port = try await startOnAnyPort(rule, in: session)

            let client = CollectingClient(group: MultiThreadedEventLoopGroup.singleton)
            try await client.connect(host: "127.0.0.1", port: port)
            let payload: [UInt8] = Array("FORWARDED_THROUGH_SSH\n".utf8)
            try await client.send(payload)
            let received = try await client.received(atLeast: payload.count)
            #expect(received == payload)
            await client.close()

            // And the counters saw the same bytes go each way.
            let traffic = await session.traffic(of: rule.id)
            #expect(traffic.bytesOut == payload.count)
            #expect(traffic.bytesIn == payload.count)
            #expect(traffic.totalConnections == 1)
        }
    }

    @Test("A service that speaks first is heard: nothing is lost before the splice")
    func greetingIsNotLost() async throws {
        let server = try #require(Self.shared, "the harness sshd did not start")
        let identity = KnownHostIdentity(host: "127.0.0.1", port: server.fixtures.port)
        let connection = try await SSHConnection.connect(
            transport: DirectTCPTransport(endpoint: TransportEndpoint(host: "127.0.0.1", port: server.fixtures.port)),
            configuration: SSHConnectionConfiguration(
                username: server.fixtures.username,
                credentials: [.privateKey(try OpenSSHPrivateKeyParser.parse(pem: server.fixtures.clientPrivateKeyPEM))],
                knownHostIdentity: identity
            ),
            hostKeyVerifier: HostKeyVerifier(
                identity: identity, store: InMemoryKnownHostsStore(), approval: TrustOnFirstUseApproval()
            ),
            eventLoop: NIOTSEventLoopGroup.singleton.next()
        )
        defer { Task { await connection.close() } }

        let greeting = "220 service ready\r\n"
        let echo = EchoServer(group: MultiThreadedEventLoopGroup.singleton, greeting: greeting)
        try await echo.start()
        defer { Task { await echo.stop() } }

        let session = ForwardingSession(connection: connection, group: NIOTSEventLoopGroup.singleton, log: .forTests)
        let rule = PortForward(kind: .local, listenPort: 0, targetHost: "127.0.0.1", targetPort: echo.port)
        let port = try await startOnAnyPort(rule, in: session)

        let client = CollectingClient(group: MultiThreadedEventLoopGroup.singleton)
        try await client.connect(host: "127.0.0.1", port: port)
        let received = try await client.received(atLeast: greeting.utf8.count)
        #expect(String(decoding: received, as: UTF8.self) == greeting)
        await client.close()
        await session.stopAll()
    }

    @Test("A port already in use is refused with a reason, not a silent failure")
    func portInUseIsExplained() async throws {
        try await withSession { session, echo, _ in
            // `get()`, never `wait()`. `wait()` blocks the thread it is called on, and in
            // an async test that thread belongs to the cooperative pool — block enough of
            // them and another suite's SSH handshake never gets a thread to resume on,
            // and reports a thirty-second timeout that has nothing to do with SSH.
            let occupied = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 0)
                .bind(host: "127.0.0.1", port: 0).get()
            let port = occupied.localAddress?.port ?? 0
            defer { occupied.close(promise: nil) }

            let rule = PortForward(kind: .local, listenPort: port, targetHost: "127.0.0.1", targetPort: echo.port)
            let state = await session.start(rule)
            guard case let .failed(message, recovery) = state else {
                Issue.record("expected a refusal, got \(state)")
                return
            }
            #expect(message.contains("\(port)"), "the message does not name the port: \(message)")
            #expect(recovery != nil, "a refusal the user can fix must say how")
        }
    }

    @Test("Stopping a forward gives the port back")
    func stoppingFreesThePort() async throws {
        try await withSession { session, echo, _ in
            var rule = PortForward(kind: .local, listenPort: 0, targetHost: "127.0.0.1", targetPort: echo.port)
            let port = try await startOnAnyPort(rule, in: session)
            await session.stop(rule.id)
            #expect(await session.state(of: rule.id) == .stopped)

            // The same rule again on the port it just held: if the listener had leaked,
            // this is where it would show up.
            rule.listenPort = port
            let restarted = await session.start(rule)
            #expect(restarted == .running(port: port), "the port was not released: \(restarted)")
        }
    }

    // MARK: - Remote forwarding

    @Test("A remote forward brings the server's connections back to a local service")
    func remoteForwardDeliversConnections() async throws {
        try await withSession { session, echo, _ in
            // Port 0 asks the server to choose, which is also the only way to be sure the
            // port is free on its side.
            let rule = PortForward(
                name: "reverse", kind: .remote, listenPort: 0,
                targetHost: "127.0.0.1", targetPort: echo.port, remoteBindHost: "127.0.0.1"
            )
            let state = await session.start(rule)
            guard case let .running(bound) = state else {
                Issue.record("the remote forward did not start: \(state)")
                return
            }
            #expect(bound > 0, "the server did not report the port it bound")

            // The server and this test share a loopback interface, so connecting here is
            // connecting to the port the *server* is listening on.
            let client = CollectingClient(group: MultiThreadedEventLoopGroup.singleton)
            try await client.connect(host: "127.0.0.1", port: bound)
            let payload: [UInt8] = Array("BACK_THROUGH_THE_TUNNEL\n".utf8)
            try await client.send(payload)
            let received = try await client.received(atLeast: payload.count)
            #expect(received == payload)
            await client.close()

            let traffic = await session.traffic(of: rule.id)
            #expect(traffic.totalConnections == 1)
        }
    }

    @Test("A cancelled remote forward stops being answered")
    func cancelledRemoteForwardStops() async throws {
        try await withSession { session, echo, _ in
            let rule = PortForward(
                kind: .remote, listenPort: 0, targetHost: "127.0.0.1", targetPort: echo.port
            )
            guard case let .running(bound) = await session.start(rule) else {
                Issue.record("the remote forward did not start")
                return
            }
            await session.stop(rule.id)

            // The server should have stopped listening. Connecting is then refused — or,
            // if something else grabbed the port in between, at least not answered by us.
            var refused = false
            do {
                let client = CollectingClient(group: MultiThreadedEventLoopGroup.singleton)
                try await client.connect(host: "127.0.0.1", port: bound)
                try await client.send(Array("still there?".utf8))
                let echoed = try await client.received(atLeast: 1, timeout: .seconds(2))
                refused = echoed.isEmpty
                await client.close()
            } catch {
                refused = true
            }
            #expect(refused, "the server was still forwarding a cancelled port")
        }
    }

    // MARK: - Dynamic forwarding

    @Test("A dynamic forward is a working SOCKS5 proxy")
    func dynamicForwardSpeaksSOCKS5() async throws {
        try await withSession { session, echo, _ in
            let rule = PortForward(name: "socks", kind: .dynamic, listenPort: 0)
            let port = try await startOnAnyPort(rule, in: session)

            let client = CollectingClient(group: MultiThreadedEventLoopGroup.singleton)
            try await client.connect(host: "127.0.0.1", port: port)

            // Greeting: version 5, one method, no authentication.
            try await client.send([5, 1, 0])
            let methodReply = try await client.received(atLeast: 2)
            #expect(Array(methodReply.prefix(2)) == [5, 0])

            // CONNECT to the echo server by IPv4 address.
            var request: [UInt8] = [5, 1, 0, 1, 127, 0, 0, 1]
            request.append(UInt8(echo.port >> 8))
            request.append(UInt8(echo.port & 0xFF))
            try await client.send(request)
            let connectReply = try await client.received(atLeast: 2 + 10)
            #expect(connectReply[2] == 5, "the reply does not start with the SOCKS version")
            #expect(connectReply[3] == 0, "the proxy reported a failure: \(connectReply[3])")

            // And now it is a plain tunnel.
            let payload: [UInt8] = Array("THROUGH_SOCKS\n".utf8)
            try await client.send(payload)
            let all = try await client.received(atLeast: 2 + 10 + payload.count)
            #expect(Array(all.suffix(payload.count)) == payload)
            await client.close()
        }
    }

    @Test("A SOCKS5 client asking for BIND is told it is not offered")
    func dynamicForwardRefusesBind() async throws {
        try await withSession { session, _, _ in
            let rule = PortForward(kind: .dynamic, listenPort: 0)
            let port = try await startOnAnyPort(rule, in: session)

            let client = CollectingClient(group: MultiThreadedEventLoopGroup.singleton)
            try await client.connect(host: "127.0.0.1", port: port)
            try await client.send([5, 1, 0])
            _ = try await client.received(atLeast: 2)
            // Command 2 is BIND.
            try await client.send([5, 2, 0, 1, 127, 0, 0, 1, 0, 80])
            let reply = try await client.received(atLeast: 2 + 10)
            #expect(reply[3] == 0x07, "expected 'command not supported', got \(reply[3])")
            await client.close()
        }
    }

    @Test("A SOCKS5 client offering no acceptable method is turned away")
    func dynamicForwardRefusesAuthOnly() async throws {
        try await withSession { session, _, _ in
            let rule = PortForward(kind: .dynamic, listenPort: 0)
            let port = try await startOnAnyPort(rule, in: session)

            let client = CollectingClient(group: MultiThreadedEventLoopGroup.singleton)
            try await client.connect(host: "127.0.0.1", port: port)
            // Only username/password (method 2) offered, which this proxy does not do.
            try await client.send([5, 1, 2])
            let reply = try await client.received(atLeast: 2)
            #expect(Array(reply.prefix(2)) == [5, 0xFF])
            await client.close()
        }
    }
}
