import Foundation
import STCore
import STSSH
import Testing
@testable import ApexTerminal

/// Exercises the whole app stack — vault, session, emulator — against a real SSH server,
/// running inside the app on a simulator or device.
///
/// The package's own tests prove the SSH and terminal layers work when driven directly.
/// This proves they work when driven the way the app drives them: through the Keychain,
/// through `TerminalSession`'s state machine, and with the emulator attached. Those are
/// different claims, and the second is the one that matters to a user.
///
/// It needs an SSH server the simulator can reach. `scripts/app-integration-e2e.sh`
/// starts one on the host — the simulator shares the Mac's loopback — and passes its
/// details in the environment. Without them the suite skips.
@Suite(
    "App stack against a real SSH server",
    .enabled(if: AppIntegrationEnvironment.current != nil, "run scripts/app-integration-e2e.sh"),
    .serialized
)
@MainActor
struct AppSSHIntegrationTests {
    private var environment: AppIntegrationEnvironment {
        get throws {
            guard let environment = AppIntegrationEnvironment.current else {
                throw AppIntegrationEnvironment.Missing()
            }
            return environment
        }
    }

    /// Builds a session wired to the real vault and a temporary host store.
    private func makeSession(_ environment: AppIntegrationEnvironment) throws -> (TerminalSession, SessionManager) {
        let keyID = UUID()
        let vault = CredentialVault()
        try vault.storePrivateKey(environment.privateKeyPEM, id: keyID, requireBiometrics: false)

        let host = Host(
            name: "Integration",
            hostname: environment.host,
            port: environment.port,
            username: environment.username,
            transport: .directTCP,
            credentials: [.privateKey(id: keyID)]
        )

        let settings = AppSettings(defaults: UserDefaults(suiteName: "app-integration-\(UUID())")!)
        let diagnostics = DiagnosticsCentre()
        let manager = SessionManager(
            vault: vault,
            knownHosts: InMemoryKnownHostsStore(),
            settings: settings,
            diagnostics: diagnostics
        )
        return (manager.open(host), manager)
    }

    /// Waits for a session state that satisfies `predicate`, or fails.
    private func waitForState(
        _ session: TerminalSession,
        timeout: Double = 30,
        describedAs description: String,
        _ predicate: (TerminalSession.State) -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(session.state) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("timed out waiting for \(description); state was \(session.state)")
        throw AppIntegrationEnvironment.Missing()
    }

    private func waitForScreen(
        _ session: TerminalSession,
        timeout: Double = 30,
        describedAs description: String,
        _ predicate: (String) -> Bool
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let text = session.screen.visibleText
            if predicate(text) { return text }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("timed out waiting for \(description). Screen:\n\(session.screen.visibleText)")
        return session.screen.visibleText
    }

    @Test("The app connects, allocates a PTY, and renders real remote output")
    func appConnectsAndRenders() async throws {
        let environment = try environment
        let (session, manager) = try makeSession(environment)
        defer { manager.closeAll() }

        // Trust-on-first-use goes through the same prompt machinery the UI uses, so
        // answering it here exercises the real path rather than bypassing it.
        try await waitForState(session, describedAs: "a host key prompt or a connection") { state in
            if case .awaitingUser = state { return true }
            if case .connected = state { return true }
            if case .failed = state { return true }
            return false
        }
        if case .awaitingUser = session.state {
            session.resolvePrompt(.approve)
        }
        try await waitForState(session, describedAs: "the session to connect") { state in
            if case .connected = state { return true }
            if case .failed = state { return true }
            return false
        }
        #expect(session.isConnected, "session state was \(session.state)")

        await session.resize(columns: 90, rows: 28)
        await session.send("stty size; printf 'APP_STACK_%s\\n' OK\n")

        let screen = try await waitForScreen(session, describedAs: "the marker") {
            $0.contains("APP_STACK_OK")
        }
        #expect(screen.contains("APP_STACK_OK"))
        // The remote shell reports the geometry the app asked for, which is only true if
        // a PTY was allocated and the resize actually reached the server.
        #expect(screen.contains("28 90"))
    }

    @Test("A host key the app has not seen is refused until the user approves it")
    func hostKeyPromptGatesTheConnection() async throws {
        let environment = try environment
        let (session, manager) = try makeSession(environment)
        defer { manager.closeAll() }

        try await waitForState(session, describedAs: "the host key prompt") { state in
            if case .awaitingUser = state { return true }
            return false
        }
        guard case let .awaitingUser(prompt) = session.state else {
            Issue.record("expected a pending prompt")
            return
        }
        guard case let .unknownHostKey(_, key) = prompt else {
            Issue.record("expected an unknown-host-key prompt, got \(prompt)")
            return
        }
        // The fingerprint the sheet will show must be the server's real one, or the user
        // is being asked to verify something meaningless.
        #expect(key.fingerprintSHA256 == environment.hostKeyFingerprint)

        session.resolvePrompt(.reject)
        try await waitForState(session, describedAs: "the refusal") { state in
            if case .failed = state { return true }
            return false
        }
        guard case let .failed(error) = session.state else {
            Issue.record("expected a failure after refusing the key")
            return
        }
        #expect(error.category == .hostKey)
    }
}

/// Details of the SSH server the app integration tests connect to.
struct AppIntegrationEnvironment {
    struct Missing: Error {}

    let host: String
    let port: Int
    let username: String
    let privateKeyPEM: String
    let hostKeyFingerprint: String

    /// The key travels as PEM text rather than a file path.
    ///
    /// A simulator can read the Mac's filesystem, but a physical device cannot — and
    /// these tests are meant to run on both. Passing the content means the same harness
    /// works either way.
    static var current: AppIntegrationEnvironment? {
        let environment = ProcessInfo.processInfo.environment
        guard let portString = environment["ST_APP_TEST_SSH_PORT"], let port = Int(portString),
              let username = environment["ST_APP_TEST_SSH_USER"],
              let pem = environment["ST_APP_TEST_SSH_KEY"], !pem.isEmpty,
              let fingerprint = environment["ST_APP_TEST_SSH_HOST_FINGERPRINT"]
        else { return nil }
        return AppIntegrationEnvironment(
            host: environment["ST_APP_TEST_SSH_HOST"] ?? "127.0.0.1",
            port: port,
            username: username,
            privateKeyPEM: pem,
            hostKeyFingerprint: fingerprint
        )
    }
}
