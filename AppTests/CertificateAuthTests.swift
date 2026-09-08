import Foundation
import STCore
import STSSH
import Testing

@testable import ApexTerminal

/// Certificates as the app uses them (D-046).
///
/// The key here is not in the server's `authorized_keys`. A session that connects with it
/// connected because the app offered the certificate and the server checked it against its
/// authority, and there is no other path available.
@Suite(
    "Certificates through the app",
    .enabled(if: AppIntegrationEnvironment.current != nil, "run scripts/app-integration-e2e.sh"),
    .serialized
)
@MainActor
struct CertificateAuthTests {
    private var certificateEnvironment: (key: String, certificate: String)? {
        let environment = ProcessInfo.processInfo.environment
        guard let key = environment["ST_APP_TEST_SSH_CERT_KEY"], !key.isEmpty,
              let certificate = environment["ST_APP_TEST_SSH_CERT"], !certificate.isEmpty
        else { return nil }
        return (key, certificate)
    }

    @Test("A key the server has never seen connects on its certificate", .timeLimit(.minutes(2)))
    func certifiedKeyConnects() async throws {
        let environment = try #require(AppIntegrationEnvironment.current)
        let issued = try #require(certificateEnvironment, "the harness did not issue a certificate")

        let keyID = UUID()
        let vault = CredentialVault()
        try vault.storePrivateKey(issued.key, id: keyID, requireBiometrics: false)
        defer { try? vault.deletePrivateKey(id: keyID) }

        let directory = URL(fileURLWithPath: NSTemporaryDirectory() + "cert-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hostStore = HostStore(directory: directory)

        let certificate = try SSHCertificate(openSSHRepresentation: issued.certificate)
        let material = try OpenSSHPrivateKeyParser.parse(pem: issued.key)
        hostStore.add(StoredKey(
            id: keyID,
            name: "certified",
            algorithm: material.algorithm,
            publicKeyOpenSSH: material.publicKey.openSSHRepresentation,
            fingerprintSHA256: material.publicKey.fingerprintSHA256,
            requiresBiometrics: false,
            isPassphraseProtected: false,
            certificate: certificate
        ))

        let host = Host(
            name: "Certified",
            hostname: environment.host,
            port: environment.port,
            username: environment.username,
            transport: .directTCP,
            credentials: [.privateKey(id: keyID)]
        )
        let manager = SessionManager(
            vault: vault,
            knownHosts: InMemoryKnownHostsStore(),
            settings: AppSettings(defaults: UserDefaults(suiteName: "cert-\(UUID())")!),
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

    @Test("The store keeps a certificate with its key, and older records still load")
    func certificatesRoundTrip() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory() + "cert-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let issued = certificateEnvironment
        let store = HostStore(directory: directory)
        var key = StoredKey(
            name: "k", algorithm: "ssh-ed25519", publicKeyOpenSSH: "ssh-ed25519 AAAA",
            fingerprintSHA256: "SHA256:x", requiresBiometrics: false, isPassphraseProtected: false
        )
        if let issued { key.certificate = try SSHCertificate(openSSHRepresentation: issued.certificate) }
        store.add(key)

        let reopened = HostStore(directory: directory)
        #expect(reopened.key(withID: key.id)?.certificate == key.certificate)

        // A key written before certificates existed has no field for one, and must still
        // decode rather than taking the whole key list down with it.
        let old = """
        [{"algorithm":"ssh-ed25519","createdAt":"2026-01-01T00:00:00Z","fingerprintSHA256":"SHA256:y",
          "id":"\(UUID().uuidString)","isPassphraseProtected":false,"name":"old",
          "publicKeyOpenSSH":"ssh-ed25519 AAAA","requiresBiometrics":false}]
        """
        try Data(old.utf8).write(to: directory.appendingPathComponent("keys.json"))
        let legacy = HostStore(directory: directory)
        #expect(legacy.keys.count == 1)
        #expect(legacy.keys.first?.certificate == nil)
        #expect(legacy.loadError == nil)
    }

    @Test("Trusted authorities are saved and come back")
    func authoritiesRoundTrip() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory() + "ca-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HostStore(directory: directory)
        let authority = SSHCertificateAuthority(
            name: "Production", openSSHPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5", hostPatterns: ["*.prod.example"]
        )
        store.add(authority)
        #expect(HostStore(directory: directory).authorities == [authority])

        store.removeAuthority(id: authority.id)
        #expect(HostStore(directory: directory).authorities.isEmpty)
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
        Issue.record("timed out waiting for \(description): \(session.state)")
    }
}
