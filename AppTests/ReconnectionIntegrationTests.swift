import Foundation
import STCore
import STSSH
import Testing
@testable import ApexTerminal

/// Automatic reconnection, against a real server and a connection that really dies.
///
/// The connection runs through a relay that can close the sockets under it. That is the
/// only way to make this claim honestly: setting the session's state by hand would prove
/// the state machine and nothing about whether a socket dying mid-session is noticed, or
/// whether what comes back is a shell that works.
@Suite(
    "Reconnection against a real SSH server",
    .enabled(if: AppIntegrationEnvironment.current != nil, "run scripts/app-integration-e2e.sh"),
    .serialized
)
@MainActor
struct ReconnectionIntegrationTests {
    private func makeSession(
        through proxy: SeverableTCPProxy,
        environment: AppIntegrationEnvironment,
        automaticReconnect: Bool = true,
        reachability: NetworkReachability? = nil
    ) throws -> (TerminalSession, SessionManager, AppSettings) {
        let keyID = UUID()
        let vault = CredentialVault()
        try vault.storePrivateKey(environment.privateKeyPEM, id: keyID, requireBiometrics: false)

        let host = Host(
            name: "Reconnect",
            hostname: "127.0.0.1",
            port: proxy.port,
            username: environment.username,
            transport: .directTCP,
            credentials: [.privateKey(id: keyID)]
        )

        let settings = AppSettings(defaults: UserDefaults(suiteName: "reconnect-\(UUID())")!)
        settings.automaticReconnect = automaticReconnect
        let manager = SessionManager(
            vault: vault,
            knownHosts: InMemoryKnownHostsStore(),
            settings: settings,
            diagnostics: DiagnosticsCentre(),
            reachability: reachability ?? NetworkReachability(start: false)
        )
        return (manager.open(host), manager, settings)
    }

    private func waitFor(
        _ description: String,
        timeout: Double = 40,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("timed out waiting for \(description)")
        throw AppIntegrationEnvironment.Missing()
    }

    private func connect(_ session: TerminalSession) async throws {
        try await waitFor("a prompt or a connection", timeout: 30) {
            if case .awaitingUser = session.state { return true }
            if case .connected = session.state { return true }
            if case .failed = session.state { return true }
            return false
        }
        if case .awaitingUser = session.state { session.resolvePrompt(.approve) }
        try await waitFor("the session to connect", timeout: 30) { session.isConnected }
    }

    @Test("A dropped connection comes back on its own, with the scrollback intact")
    func reconnectsAfterARealDrop() async throws {
        guard let environment = AppIntegrationEnvironment.current else { return }
        let proxy = SeverableTCPProxy(originHost: environment.host, originPort: environment.port)
        try await proxy.start()
        defer { Task { await proxy.shutdown() } }

        let (session, manager, _) = try makeSession(through: proxy, environment: environment)
        defer { manager.closeAll() }
        try await connect(session)

        await session.send("printf 'BEFORE_%s\\n' DROP\n")
        try await waitFor("output from before the drop") {
            session.screen.visibleText.contains("BEFORE_DROP")
        }

        // A real drop: the sockets carrying this session are closed underneath it, with
        // no SSH disconnect message, exactly as a network going away would.
        proxy.sever()

        try await waitFor("the session to notice the drop") {
            session.reconnection != nil || !session.isConnected
        }
        try await waitFor("reconnection to start") { session.reconnection != nil }

        try await waitFor("the session to come back", timeout: 60) { session.isConnected }
        #expect(session.reconnection == nil, "the banner should clear once it is back")

        // The point of keeping the buffer: what was on screen when the link went is the
        // record of what happened, and clearing it to look tidy destroys it.
        let everything = session.screen.allLines.map(\.text).joined(separator: "\n")
        #expect(
            everything.contains("BEFORE_DROP"),
            "the output from before the drop should still be readable"
        )

        // And it is a working shell, not merely a connected socket.
        await session.send("printf 'AFTER_%s\\n' DROP\n")
        try await waitFor("output from the new shell", timeout: 30) {
            session.screen.visibleText.contains("AFTER_DROP")
        }
    }

    @Test("While the server is unreachable it keeps trying, and stops when told to")
    func retriesWhileUnreachableAndStopsOnRequest() async throws {
        guard let environment = AppIntegrationEnvironment.current else { return }
        let proxy = SeverableTCPProxy(originHost: environment.host, originPort: environment.port)
        try await proxy.start()
        defer { Task { await proxy.shutdown() } }

        let (session, manager, _) = try makeSession(through: proxy, environment: environment)
        defer { manager.closeAll() }
        try await connect(session)

        // Down, and staying down: new connections are refused as well.
        proxy.allowConnections = false
        proxy.sever()

        try await waitFor("reconnection to start") { session.reconnection != nil }
        try await waitFor("at least two attempts", timeout: 40) {
            (session.reconnection?.attempt ?? 0) >= 2
        }
        #expect(!session.isConnected)

        // The user can call it off; nothing should carry on behind their back.
        session.cancelAutomaticReconnection()
        #expect(session.reconnection == nil)
        try await Task.sleep(for: .seconds(2))
        #expect(session.reconnection == nil, "cancelling must actually stop it")
        #expect(!session.isConnected)
    }

    @Test("Retry now skips the wait")
    func retryNowSkipsTheWait() async throws {
        guard let environment = AppIntegrationEnvironment.current else { return }
        let proxy = SeverableTCPProxy(originHost: environment.host, originPort: environment.port)
        try await proxy.start()
        defer { Task { await proxy.shutdown() } }

        let (session, manager, _) = try makeSession(through: proxy, environment: environment)
        defer { manager.closeAll() }
        try await connect(session)

        proxy.allowConnections = false
        proxy.sever()
        try await waitFor("a wait between attempts", timeout: 40) {
            session.reconnection?.nextAttempt != nil
        }

        proxy.allowConnections = true
        session.retryNow()
        // Without the button this would sit out the remaining backoff.
        try await waitFor("an immediate reconnection", timeout: 20) { session.isConnected }
    }

    @Test("Turning automatic reconnection off means the app waits for the user")
    func settingIsHonoured() async throws {
        guard let environment = AppIntegrationEnvironment.current else { return }
        let proxy = SeverableTCPProxy(originHost: environment.host, originPort: environment.port)
        try await proxy.start()
        defer { Task { await proxy.shutdown() } }

        let (session, manager, _) = try makeSession(
            through: proxy,
            environment: environment,
            automaticReconnect: false
        )
        defer { manager.closeAll() }
        try await connect(session)

        proxy.sever()
        try await waitFor("the session to notice the drop") { !session.isConnected }
        try await Task.sleep(for: .seconds(3))
        #expect(session.reconnection == nil, "nothing should retry when the setting is off")
    }

    @Test("A shell the user exits is not treated as a drop")
    func exitingTheShellDoesNotReconnect() async throws {
        guard let environment = AppIntegrationEnvironment.current else { return }
        let proxy = SeverableTCPProxy(originHost: environment.host, originPort: environment.port)
        try await proxy.start()
        defer { Task { await proxy.shutdown() } }

        let (session, manager, _) = try makeSession(through: proxy, environment: environment)
        defer { manager.closeAll() }
        try await connect(session)

        await session.send("exit\n")
        try await waitFor("the session to end", timeout: 30) { !session.isConnected }
        try await Task.sleep(for: .seconds(3))
        // Reconnecting after `exit` would reopen a session the user deliberately ended.
        #expect(session.reconnection == nil, "typing exit must not start a reconnection")
        if case let .disconnected(reason) = session.state {
            #expect(reason == "The shell exited.")
        } else {
            Issue.record("expected a clean disconnect, got \(session.state)")
        }
    }

    @Test("Coming back onto a network retries at once instead of waiting")
    func networkReturnWakesTheRetry() async throws {
        guard let environment = AppIntegrationEnvironment.current else { return }
        let proxy = SeverableTCPProxy(originHost: environment.host, originPort: environment.port)
        try await proxy.start()
        defer { Task { await proxy.shutdown() } }

        let reachability = NetworkReachability(start: false)
        let (session, manager, _) = try makeSession(
            through: proxy,
            environment: environment,
            reachability: reachability
        )
        defer { manager.closeAll() }
        try await connect(session)

        reachability.simulate(online: false, interface: .none)
        proxy.allowConnections = false
        proxy.sever()

        try await waitFor("the session to wait for a network", timeout: 30) {
            session.reconnection?.isWaitingForNetwork == true
        }
        // Attempts spent while offline teach nothing, and running out of them just as the
        // user leaves the tunnel is the worst possible moment to give up.
        let attemptsWhileOffline = session.reconnection?.attempt ?? 0
        try await Task.sleep(for: .seconds(3))
        #expect(session.reconnection?.attempt == attemptsWhileOffline, "offline time must not burn attempts")

        proxy.allowConnections = true
        reachability.simulate(online: true, interface: .wifi)
        try await waitFor("an immediate reconnection", timeout: 30) { session.isConnected }
    }
}
