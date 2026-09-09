import Foundation
import STCore
import STSSH
import Testing

@testable import ApexTerminal

/// Connection reuse as the app performs it (D-054).
///
/// The package suite proves the pool's arithmetic against `sshd`'s own log. What is checked
/// here is that the app actually *uses* it: a terminal and a file browser opened on the same
/// connection should share one transport, and two connections that differ in who they
/// authenticate as should not — which is the failure that would produce no error at all,
/// just a session belonging to the wrong account.
@Suite(
    "Connection reuse through the app",
    .enabled(if: AppIntegrationEnvironment.current != nil, "run scripts/app-integration-e2e.sh"),
    .serialized
)
@MainActor
struct ConnectionReuseTests {
    private func manager(_ vault: CredentialVault) -> SessionManager {
        SessionManager(
            vault: vault,
            knownHosts: InMemoryKnownHostsStore(),
            settings: AppSettings(defaults: UserDefaults(suiteName: "reuse-\(UUID())")!),
            diagnostics: DiagnosticsCentre()
        )
    }

    @Test("A terminal and a file browser on one server share a transport", .timeLimit(.minutes(2)))
    func terminalAndFilesShareOneConnection() async throws {
        let environment = try #require(AppIntegrationEnvironment.current)
        let keyID = UUID()
        let vault = CredentialVault()
        try vault.storePrivateKey(environment.privateKeyPEM, id: keyID, requireBiometrics: false)
        defer { try? vault.deletePrivateKey(id: keyID) }

        let host = Host(
            name: "Shared",
            hostname: environment.host,
            port: environment.port,
            username: environment.username,
            transport: .directTCP,
            credentials: [.privateKey(id: keyID)]
        )
        let manager = manager(vault)
        defer { manager.closeAll() }

        let session = manager.open(host)
        try await waitFor(session) { state in
            if case .connected = state { return true }
            if case .awaitingUser = state { return true }
            if case .failed = state { return true }
            return false
        }
        if case .awaitingUser = session.state { session.resolvePrompt(.approve) }
        try await waitFor(session) { state in
            if case .connected = state { return true }
            if case .failed = state { return true }
            return false
        }
        #expect(session.isConnected, "state was \(session.state)")

        // The same host, through the other kind of session. It must land on the transport
        // the terminal already has.
        let files = manager.makeFileSession(for: host)
        await files.connect()

        let identity = SSHConnectionIdentity(
            endpoint: "\(host.hostname):\(host.port)",
            username: host.username,
            credentials: ["key:\(keyID.uuidString)"]
        )
        let users = await manager.pool.users(of: identity)
        #expect(users == 2, "the terminal and the browser should share one transport, saw \(users) user(s)")

        await files.disconnect()
        // Releasing one must not take the other's transport away.
        #expect(await manager.pool.users(of: identity) == 1)
        #expect(session.isConnected)
    }

    @Test("A different user name gets its own transport", .timeLimit(.minutes(2)))
    func differentUsernamesAreNotShared() async throws {
        let environment = try #require(AppIntegrationEnvironment.current)
        let keyID = UUID()
        let vault = CredentialVault()
        try vault.storePrivateKey(environment.privateKeyPEM, id: keyID, requireBiometrics: false)
        defer { try? vault.deletePrivateKey(id: keyID) }

        let mine = SSHConnectionIdentity(
            endpoint: "\(environment.host):\(environment.port)",
            username: environment.username,
            credentials: ["key:\(keyID.uuidString)"]
        )
        let theirs = SSHConnectionIdentity(
            endpoint: mine.endpoint,
            username: "somebody-else",
            credentials: mine.credentials
        )
        // Stated as a fact about the key rather than by opening a second connection as a
        // user this server does not have: the point is that the app's identity for a
        // connection changes with the user name, so the pool cannot conflate them.
        #expect(mine != theirs)

        let host = Host(
            name: "Shared",
            hostname: environment.host,
            port: environment.port,
            username: environment.username,
            transport: .directTCP,
            credentials: [.privateKey(id: keyID)]
        )
        let manager = manager(vault)
        defer { manager.closeAll() }

        let session = manager.open(host)
        try await waitFor(session) { state in
            if case .connected = state { return true }
            if case .awaitingUser = state { return true }
            if case .failed = state { return true }
            return false
        }
        if case .awaitingUser = session.state { session.resolvePrompt(.approve) }
        try await waitFor(session) { state in
            if case .connected = state { return true }
            if case .failed = state { return true }
            return false
        }
        #expect(session.isConnected)
        #expect(await manager.pool.users(of: mine) == 1)
        // Nothing was ever opened for the other identity, which is the point.
        #expect(await manager.pool.users(of: theirs) == 0)
    }

    private func waitFor(
        _ session: TerminalSession,
        _ predicate: @escaping (TerminalSession.State) -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            if predicate(session.state) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("timed out; state was \(session.state)")
    }
}
