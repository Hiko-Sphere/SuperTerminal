import Foundation
import NIOCore
import NIOTransportServices
import STCore
import STForwarding
import STSSH
import Testing

@testable import ApexTerminal

/// Port forwarding as the app runs it (D-045).
///
/// The package's own tests prove the three kinds of forward carry bytes when driven
/// directly. This proves they work when driven the way the app drives them: rules saved on
/// a connection, started by a `TerminalSession`, over the connection the app opened.
///
/// The destination is the test server's own SSH port. That is deliberate — it is a real
/// service, it is already running, and it speaks first, so a forward that loses the first
/// thing a service says cannot pass.
@Suite(
    "Port forwarding through the app",
    .enabled(if: AppIntegrationEnvironment.current != nil, "run scripts/app-integration-e2e.sh"),
    .serialized
)
@MainActor
struct PortForwardingTests {
    private func connectedSession(
        rules: [PortForward]
    ) async throws -> (TerminalSession, SessionManager, AppIntegrationEnvironment) {
        let environment = try #require(AppIntegrationEnvironment.current)
        let keyID = UUID()
        let vault = CredentialVault()
        try vault.storePrivateKey(environment.privateKeyPEM, id: keyID, requireBiometrics: false)

        var host = Host(
            name: "Forwarding",
            hostname: environment.host,
            port: environment.port,
            username: environment.username,
            transport: .directTCP,
            credentials: [.privateKey(id: keyID)]
        )
        host.portForwards = rules

        let settings = AppSettings(defaults: UserDefaults(suiteName: "forwarding-\(UUID())")!)
        let manager = SessionManager(
            vault: vault,
            knownHosts: InMemoryKnownHostsStore(),
            settings: settings,
            diagnostics: DiagnosticsCentre()
        )
        let session = manager.open(host)
        // The host key goes through the same prompt the interface uses; answering it here
        // exercises the real path rather than stepping around it.
        try await waitFor(session, until: "a host key prompt or a connection") { state in
            if case .awaitingUser = state { return true }
            if case .connected = state { return true }
            if case .failed = state { return true }
            return false
        }
        if case .awaitingUser = session.state { session.resolvePrompt(.approve) }
        try await waitFor(session, until: "the session to connect") { state in
            if case .connected = state { return true }
            if case .failed = state { return true }
            return false
        }
        guard case .connected = session.state else {
            throw SessionDidNotConnect(state: String(describing: session.state))
        }
        return (session, manager, environment)
    }

    private func waitFor(
        _ session: TerminalSession,
        until description: String,
        timeout: Duration = .seconds(30),
        _ predicate: (TerminalSession.State) -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if predicate(session.state) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw SessionDidNotConnect(state: "timed out waiting for \(description): \(session.state)")
    }

    private struct SessionDidNotConnect: Error, CustomStringConvertible {
        let state: String
        var description: String { "the session did not connect: \(state)" }
    }

    /// Reads whatever a TCP port says when connected to, which for an SSH server is its
    /// version string.
    private func firstBytes(from port: Int, count: Int, timeout: Duration = .seconds(15)) async throws -> String {
        let collector = ByteCollector()
        let channel = try await NIOTSConnectionBootstrap(group: NIOTSEventLoopGroup.singleton)
            .channelInitializer { channel in
                channel.pipeline.addHandler(CollectingTestHandler(collector: collector))
            }
            .connect(host: "127.0.0.1", port: port)
            .get()
        // Not `wait()`: it blocks a cooperative thread, and starving that pool makes
        // unrelated async work look like it timed out.
        defer { channel.close(promise: nil) }

        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if collector.bytes.count >= count { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        return String(decoding: collector.bytes, as: UTF8.self)
    }

    /// A port the system has just handed back.
    ///
    /// There is a race here — something else can take it before the forward binds it — and
    /// the package's own tests avoid it by binding zero. The app's rules cannot: the
    /// editor requires a real port, because a person has to know where to point their
    /// client. So the number is asked for and used immediately.
    private func freePort() async -> Int {
        guard let channel = try? await NIOTSListenerBootstrap(group: NIOTSEventLoopGroup.singleton)
            .bind(host: "127.0.0.1", port: 0)
            .get()
        else { return 0 }
        let port = channel.localAddress?.port ?? 0
        try? await channel.close().get()
        return port
    }

    @Test("A rule marked to start with the connection is running once it connects", .timeLimit(.minutes(2)))
    func autoStartedForwardCarriesBytes() async throws {
        let environment = try #require(AppIntegrationEnvironment.current)
        let port = await freePort()
        let (session, manager, _) = try await connectedSession(rules: [
            PortForward(
                name: "to the server's own sshd",
                kind: .local,
                listenPort: port,
                targetHost: "127.0.0.1",
                targetPort: environment.port,
                startsAutomatically: true
            ),
        ])
        defer { Task { await session.disconnect(); manager.closeAll() } }

        await session.refreshForwardStates()
        let rule = try #require(session.host.portForwards?.first)
        #expect(session.forwardStates[rule.id]?.state.isRunning == true,
                "the rule did not start with the connection: \(String(describing: session.forwardStates[rule.id]?.state))")

        // Through the forward, to a real SSH server, which says who it is first.
        let banner = try await firstBytes(from: port, count: 8)
        #expect(banner.hasPrefix("SSH-2.0-"), "the forward did not carry the server's banner: \(banner.debugDescription)")

        await session.refreshForwardStates()
        let traffic = try #require(session.forwardStates[rule.id]?.traffic)
        #expect(traffic.totalConnections == 1)
        #expect(traffic.bytesIn > 0, "no bytes were counted coming back")
    }

    @Test("A rule not marked to start stays stopped until it is started by hand", .timeLimit(.minutes(2)))
    func manualForwardStartsAndStops() async throws {
        let port = await freePort()
        let rule = PortForward(
            kind: .local, listenPort: port,
            targetHost: "127.0.0.1", targetPort: 22, startsAutomatically: false
        )
        let (session, manager, environment) = try await connectedSession(rules: [rule])
        _ = environment
        defer { Task { await session.disconnect(); manager.closeAll() } }

        await session.refreshForwardStates()
        #expect(session.forwardStates[rule.id] == nil, "a rule that was not asked to start is running")

        var pointed = rule
        pointed.targetPort = environment.port
        await session.startForward(pointed)
        #expect(session.forwardStates[rule.id]?.state.isRunning == true)

        await session.stopForward(rule.id)
        #expect(session.forwardStates[rule.id]?.state == .stopped)
    }

    @Test("Disconnecting stops every forward rather than leaving them claiming to run", .timeLimit(.minutes(2)))
    func disconnectingStopsForwards() async throws {
        let port = await freePort()
        let (session, manager, environment) = try await connectedSession(rules: [
            PortForward(
                kind: .local, listenPort: port,
                targetHost: "127.0.0.1", targetPort: 0, startsAutomatically: false
            ),
        ])
        defer { Task { manager.closeAll() } }

        var rule = try #require(session.host.portForwards?.first)
        rule.targetPort = environment.port
        await session.startForward(rule)
        #expect(session.forwardStates[rule.id]?.state.isRunning == true)

        await session.disconnect()
        #expect(session.forwardStates.isEmpty, "forwards outlived the connection they run over")

        // And the port really is free again: something else can take it.
        let channel = try await NIOTSListenerBootstrap(group: NIOTSEventLoopGroup.singleton)
            .bind(host: "127.0.0.1", port: port)
            .get()
        try await channel.close().get()
    }
}

/// Collects bytes from a channel for the assertions above.
final class ByteCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UInt8] = []

    var bytes: [UInt8] { lock.withLock { storage } }

    func append(_ new: [UInt8]) { lock.withLock { storage.append(contentsOf: new) } }
}

/// `@unchecked Sendable` because a `ChannelHandler` is not, and NIO's channel initialiser
/// is: the handler is constructed inside that closure, touches nothing but the collector it
/// is given — which does its own locking — and is only ever used by the event loop it is
/// added to.
private final class CollectingTestHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let collector: ByteCollector

    init(collector: ByteCollector) {
        self.collector = collector
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        collector.append(buffer.readBytes(length: buffer.readableBytes) ?? [])
    }
}
