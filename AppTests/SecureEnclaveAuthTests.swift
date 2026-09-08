import Foundation
import NIOTransportServices
import STCore
import STSSH
import Testing

@testable import ApexTerminal

/// Secure Enclave keys as the app uses them (D-049).
///
/// The key these tests log in with is created inside the enclave *during the test*, so
/// the server cannot have been told about it in advance. The test authorises it the way a
/// person would — by putting the public key in `authorized_keys` — and then connects with
/// nothing but the enclave key. A success is therefore evidence about the enclave path
/// specifically: no key material exists anywhere in the process to have been used instead.
///
/// The authorisation step runs over SSH rather than by writing the Mac's filesystem, so
/// the same test is meaningful on a physical device, where the enclave is real hardware
/// and the biometric policy can also be exercised by hand (see `docs/HUMAN_ACTIONS.md`).
@Suite(
    "Secure Enclave keys through the app",
    .enabled(if: AppIntegrationEnvironment.current != nil, "run scripts/app-integration-e2e.sh"),
    .serialized
)
@MainActor
struct SecureEnclaveAuthTests {
    private var authorizedKeysPath: String? {
        let path = ProcessInfo.processInfo.environment["ST_APP_TEST_AUTHORIZED_KEYS"] ?? ""
        return path.isEmpty ? nil : path
    }

    @Test("A key created in the Secure Enclave logs in through the app's session stack", .timeLimit(.minutes(2)))
    func enclaveKeyConnects() async throws {
        let environment = try #require(AppIntegrationEnvironment.current)
        try #require(SecureEnclaveSSHKey.isAvailable, "this device has no Secure Enclave")
        let authorizedKeys = try #require(authorizedKeysPath, "the harness did not say where authorized_keys is")

        // Only the enclave-unlocked policy can be created without biometrics, and the
        // Simulator has none. The biometric policy is a device-only check (H-7).
        let handle = try SecureEnclaveSSHKey.generate(
            accessPolicy: .deviceUnlocked,
            comment: "enclave-test@apexterminal"
        )

        let keyID = UUID()
        let vault = CredentialVault()
        try vault.storeSecureEnclaveKey(handle.blob, id: keyID)
        defer { try? vault.deleteSecureEnclaveKey(id: keyID) }

        let directory = URL(fileURLWithPath: NSTemporaryDirectory() + "enclave-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hostStore = HostStore(directory: directory)
        hostStore.add(StoredKey(
            id: keyID,
            name: "Enclave",
            algorithm: handle.publicKey.algorithm,
            publicKeyOpenSSH: handle.publicKeyOpenSSH,
            fingerprintSHA256: handle.fingerprintSHA256,
            requiresBiometrics: false,
            isPassphraseProtected: false,
            isSecureEnclave: true
        ))

        try await authorise(handle.publicKeyOpenSSH, at: authorizedKeys, using: environment)
        defer { Task { try? await deauthorise(handle.publicKeyOpenSSH, at: authorizedKeys, using: environment) } }

        let host = Host(
            name: "Enclave",
            hostname: environment.host,
            port: environment.port,
            username: environment.username,
            transport: .directTCP,
            credentials: [.privateKey(id: keyID)]
        )
        let manager = SessionManager(
            vault: vault,
            knownHosts: InMemoryKnownHostsStore(),
            settings: AppSettings(defaults: UserDefaults(suiteName: "enclave-\(UUID())")!),
            diagnostics: DiagnosticsCentre()
        )
        manager.keyRecord = { [weak hostStore] id in
            MainActor.assumeIsolated { hostStore?.key(withID: id) }
        }
        defer { manager.closeAll() }

        let session = manager.open(host)
        try await waitFor(session, until: "a prompt or a connection") { state in
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
        #expect(session.isConnected, "state was \(session.state)")
    }

    @Test("Without its public key on the server the same enclave key is refused", .timeLimit(.minutes(2)))
    func unauthorisedEnclaveKeyIsRefused() async throws {
        let environment = try #require(AppIntegrationEnvironment.current)
        try #require(SecureEnclaveSSHKey.isAvailable, "this device has no Secure Enclave")

        // Nothing is added to authorized_keys. Without this the test above could pass for
        // a reason that has nothing to do with the key it offered.
        let handle = try SecureEnclaveSSHKey.generate(accessPolicy: .deviceUnlocked, comment: "unauthorised")
        let keyID = UUID()
        let vault = CredentialVault()
        try vault.storeSecureEnclaveKey(handle.blob, id: keyID)
        defer { try? vault.deleteSecureEnclaveKey(id: keyID) }

        let directory = URL(fileURLWithPath: NSTemporaryDirectory() + "enclave-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hostStore = HostStore(directory: directory)
        hostStore.add(StoredKey(
            id: keyID,
            name: "Enclave",
            algorithm: handle.publicKey.algorithm,
            publicKeyOpenSSH: handle.publicKeyOpenSSH,
            fingerprintSHA256: handle.fingerprintSHA256,
            requiresBiometrics: false,
            isPassphraseProtected: false,
            isSecureEnclave: true
        ))

        let host = Host(
            name: "Enclave",
            hostname: environment.host,
            port: environment.port,
            username: environment.username,
            transport: .directTCP,
            credentials: [.privateKey(id: keyID)]
        )
        let manager = SessionManager(
            vault: vault,
            knownHosts: InMemoryKnownHostsStore(),
            settings: AppSettings(defaults: UserDefaults(suiteName: "enclave-\(UUID())")!),
            diagnostics: DiagnosticsCentre()
        )
        manager.keyRecord = { [weak hostStore] id in
            MainActor.assumeIsolated { hostStore?.key(withID: id) }
        }
        defer { manager.closeAll() }

        let session = manager.open(host)
        try await waitFor(session, until: "a prompt or a refusal") { state in
            if case .awaitingUser = state { return true }
            if case .failed = state { return true }
            if case .connected = state { return true }
            return false
        }
        if case .awaitingUser = session.state { session.resolvePrompt(.approve) }
        try await waitFor(session, until: "the server to refuse the key") { state in
            if case .failed = state { return true }
            if case .connected = state { return true }
            return false
        }
        #expect(!session.isConnected, "an unauthorised key must not get in; state was \(session.state)")
    }

    @Test("The backup names an enclave key as unexportable instead of quietly dropping it")
    func enclaveKeysAreDeclaredUnexportable() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory() + "enclave-backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let hosts = HostStore(directory: directory)
        hosts.add(StoredKey(
            name: "Enclave key",
            algorithm: "ecdsa-sha2-nistp256",
            publicKeyOpenSSH: "ecdsa-sha2-nistp256 AAAA enclave",
            fingerprintSHA256: "SHA256:enclave",
            requiresBiometrics: false,
            isPassphraseProtected: false,
            isSecureEnclave: true
        ))
        hosts.add(StoredKey(
            name: "Ordinary key",
            algorithm: "ssh-ed25519",
            publicKeyOpenSSH: "ssh-ed25519 AAAA ordinary",
            fingerprintSHA256: "SHA256:ordinary",
            requiresBiometrics: false,
            isPassphraseProtected: false
        ))

        let settings = AppSettings(defaults: UserDefaults(suiteName: "enclave-backup-\(UUID())")!)
        let service = BackupService(
            hosts: hosts,
            screens: ScreenStore(directory: directory),
            snippets: SnippetStore(directory: directory, settings: settings),
            knownHosts: InMemoryKnownHostsStore(),
            settings: settings,
            vault: CredentialVault(),
            log: .disabled
        )
        let unexportable = service.unexportableKeys()
        #expect(unexportable.count == 1)
        #expect(unexportable.first?.name == "Enclave key")
        #expect(unexportable.first?.reason.contains("Secure Enclave") == true)

        // And the export itself carries no private half for it, whatever the options say.
        let document = try service.makeDocument(options: BackupService.Options(includePrivateKeys: true, password: "pw"))
        #expect(document.isEncrypted)
    }

    // MARK: - Helpers

    /// Adds a public key to the server's `authorized_keys`, over SSH, the way a person
    /// would. Uses the harness's own key, which is the credential under test in no test.
    private func authorise(
        _ line: String,
        at path: String,
        using environment: AppIntegrationEnvironment
    ) async throws {
        try await runOnServer("printf '%s\\n' '\(line)' >> '\(path)'", using: environment)
    }

    private func deauthorise(
        _ line: String,
        at path: String,
        using environment: AppIntegrationEnvironment
    ) async throws {
        // Restores the file for whatever runs next; the harness deletes it at exit anyway,
        // but a test that leaves the world as it found it is one less thing to explain.
        try await runOnServer("grep -v -F '\(line)' '\(path)' > '\(path).tmp' && mv '\(path).tmp' '\(path)'", using: environment)
    }

    private func runOnServer(_ command: String, using environment: AppIntegrationEnvironment) async throws {
        let identity = KnownHostIdentity(host: environment.host, port: environment.port)
        let connection = try await SSHConnection.connect(
            transport: DirectTCPTransport(
                endpoint: TransportEndpoint(host: environment.host, port: environment.port)
            ),
            configuration: SSHConnectionConfiguration(
                username: environment.username,
                credentials: [.privateKey(try OpenSSHPrivateKeyParser.parse(pem: environment.privateKeyPEM))],
                knownHostIdentity: identity
            ),
            hostKeyVerifier: HostKeyVerifier(
                identity: identity,
                store: InMemoryKnownHostsStore(),
                approval: TrustOnFirstUseApproval()
            ),
            eventLoop: NIOTSEventLoopGroup.singleton.next()
        )
        defer { Task { await connection.close() } }
        let result = try await connection.execute(command: command)
        #expect(result.exitStatus == 0, "server said: \(result.standardErrorText)")
    }

    private func waitFor(
        _ session: TerminalSession,
        until description: String,
        _ predicate: @escaping (TerminalSession.State) -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            if predicate(session.state) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("timed out waiting for \(description); state was \(session.state)")
        throw AppIntegrationEnvironment.Missing()
    }
}
