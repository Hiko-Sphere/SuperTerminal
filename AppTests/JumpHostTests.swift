import Foundation
import STCore
import STSSH
import Testing

@testable import ApexTerminal

/// Jump hosts as the app runs them (D-047).
///
/// Two real `sshd` processes with different host keys. A session that reached the second
/// one recorded the second one's key, which is what tells "went through the bastion" apart
/// from "never left it" when both are on the same loopback.
@Suite(
    "Jump hosts through the app",
    .enabled(if: AppIntegrationEnvironment.current != nil, "run scripts/app-integration-e2e.sh"),
    .serialized
)
@MainActor
struct JumpHostAppTests {
    private var secondPort: Int? {
        ProcessInfo.processInfo.environment["ST_APP_TEST_SSH_PORT2"].flatMap { Int($0) }
    }

    private struct Fixture {
        var manager: SessionManager
        var store: HostStore
        var knownHosts: InMemoryKnownHostsStore
        var bastion: Host
        var destination: Host
    }

    private func makeFixture(jumpThroughBastion: Bool) throws -> Fixture {
        let environment = try #require(AppIntegrationEnvironment.current)
        let port2 = try #require(secondPort, "the harness did not start a second server")

        let keyID = UUID()
        let vault = CredentialVault()
        try vault.storePrivateKey(environment.privateKeyPEM, id: keyID, requireBiometrics: false)

        let directory = URL(fileURLWithPath: NSTemporaryDirectory() + "jump-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = HostStore(directory: directory)

        let bastion = Host(
            name: "Bastion", hostname: environment.host, port: environment.port,
            username: environment.username, credentials: [.privateKey(id: keyID)]
        )
        var destination = Host(
            name: "Destination", hostname: environment.host, port: port2,
            username: environment.username, credentials: [.privateKey(id: keyID)]
        )
        if jumpThroughBastion { destination.jumpHosts = [bastion.id] }
        store.add(bastion)
        store.add(destination)

        let knownHosts = InMemoryKnownHostsStore()
        let manager = SessionManager(
            vault: vault,
            knownHosts: knownHosts,
            settings: AppSettings(defaults: UserDefaults(suiteName: "jump-\(UUID())")!),
            diagnostics: DiagnosticsCentre()
        )
        manager.hostByID = { [weak store] id in
            MainActor.assumeIsolated { store?.hosts.first { $0.id == id } }
        }
        return Fixture(
            manager: manager, store: store, knownHosts: knownHosts,
            bastion: bastion, destination: destination
        )
    }

    @Test("A connection with a jump host reaches the far server through it", .timeLimit(.minutes(2)))
    func jumpReachesTheFarServer() async throws {
        let fixture = try makeFixture(jumpThroughBastion: true)
        defer { fixture.manager.closeAll() }

        let session = fixture.manager.open(fixture.destination)
        try await connect(session)
        #expect(session.isConnected, "state was \(session.state)")

        // Both hops were checked, each against its own identity — a chain is not one
        // trust decision.
        let entries = try await fixture.knownHosts.all()
        #expect(entries.count == 2, "each hop has its own host key record: \(entries.map(\.identity.storageKey))")
        #expect(Set(entries.map(\.identity.port)) == [fixture.bastion.port, fixture.destination.port])

        // And the shell really is on the far server.
        await session.send("printf 'JUMP_%s\\n' OK\n")
        let screen = try await waitForScreen(session, containing: "JUMP_OK")
        #expect(screen.contains("JUMP_OK"))
    }

    @Test("Without the jump host the same connection still works, directly", .timeLimit(.minutes(2)))
    func directStillWorks() async throws {
        let fixture = try makeFixture(jumpThroughBastion: false)
        defer { fixture.manager.closeAll() }

        let session = fixture.manager.open(fixture.destination)
        try await connect(session)
        #expect(session.isConnected)
        let entries = try await fixture.knownHosts.all()
        #expect(entries.count == 1, "a direct connection touches one host")
    }

    @Test("A chain that names a connection this app cannot resolve is ignored, not fatal", .timeLimit(.minutes(2)))
    func unknownHopIsSkipped() async throws {
        var fixture = try makeFixture(jumpThroughBastion: false)
        defer { fixture.manager.closeAll() }
        // A hop whose connection has been deleted. The chain skips it rather than failing:
        // the alternative is a connection that cannot be opened and cannot be repaired
        // from the screen it fails on.
        fixture.destination.jumpHosts = [UUID()]

        let session = fixture.manager.open(fixture.destination)
        try await connect(session)
        #expect(session.isConnected)
    }

    @Test("A connection cannot jump through itself", .timeLimit(.minutes(2)))
    func selfJumpIsIgnored() async throws {
        var fixture = try makeFixture(jumpThroughBastion: false)
        defer { fixture.manager.closeAll() }
        fixture.destination.jumpHosts = [fixture.destination.id]

        // Following it would recurse until something ran out; it is dropped instead.
        let session = fixture.manager.open(fixture.destination)
        try await connect(session)
        #expect(session.isConnected)
    }

    @Test("A failing hop is named, not hidden behind a generic failure", .timeLimit(.minutes(2)))
    func failingHopIsNamed() async throws {
        var fixture = try makeFixture(jumpThroughBastion: false)
        defer { fixture.manager.closeAll() }

        // A bastion pointing at a port nothing is listening on.
        var deadBastion = fixture.bastion
        deadBastion.id = UUID()
        deadBastion.name = "Dead bastion"
        deadBastion.port = 1
        fixture.store.add(deadBastion)
        fixture.destination.jumpHosts = [deadBastion.id]

        let session = fixture.manager.open(fixture.destination)
        try await waitFor(session, until: "a failure") { state in
            if case .failed = state { return true }
            if case .connected = state { return true }
            return false
        }
        guard case let .failed(error) = session.state else {
            Issue.record("expected a failure, got \(session.state)")
            return
        }
        #expect(error.message.contains("Dead bastion"), "the message should name the hop: \(error.message)")
    }

    // MARK: - Helpers

    private func connect(_ session: TerminalSession) async throws {
        try await waitFor(session, until: "a prompt or a connection") { state in
            if case .awaitingUser = state { return true }
            if case .connected = state { return true }
            if case .failed = state { return true }
            return false
        }
        // Each hop asks about its host key in turn, through the same prompt the interface
        // uses; answering them here exercises the real path.
        for _ in 0 ..< 4 {
            guard case .awaitingUser = session.state else { break }
            session.resolvePrompt(.approve)
            try await waitFor(session, until: "the next step") { state in
                if case .awaitingUser = state { return true }
                if case .connected = state { return true }
                if case .failed = state { return true }
                return false
            }
        }
        try await waitFor(session, until: "the session to connect") { state in
            if case .connected = state { return true }
            if case .failed = state { return true }
            return false
        }
    }

    private func waitFor(
        _ session: TerminalSession,
        until description: String,
        timeout: Duration = .seconds(40),
        _ predicate: (TerminalSession.State) -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if predicate(session.state) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("timed out waiting for \(description): \(session.state)")
    }

    private func waitForScreen(
        _ session: TerminalSession,
        containing marker: String,
        timeout: Duration = .seconds(30)
    ) async throws -> String {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let screen = session.screenText
            if screen.contains(marker) { return screen }
            try await Task.sleep(for: .milliseconds(100))
        }
        return session.screenText
    }
}
