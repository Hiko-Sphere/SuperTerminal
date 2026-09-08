import Crypto
import Foundation
import NIOTransportServices
import STCore
@testable import STSSH
import STTestSupport
import Testing

/// Secure Enclave SSH keys, against a real OpenSSH server (D-049).
///
/// The proof these tests are after is narrow and specific: a key whose private half the
/// process never sees can still sign an SSH user-auth request that OpenSSH accepts. Every
/// signature here is produced by the enclave, and the server's acceptance is the only
/// evidence that the wire format is right — a unit test comparing bytes could agree with
/// itself while being wrong about what sshd expects.
@Suite("Secure Enclave keys against real OpenSSH", .serialized)
struct SecureEnclaveKeyTests {
    /// The Simulator and every device have an enclave; a CI machine might not. Skipping
    /// is honest where refusing to build would not be, and the skip is loud.
    private func requireEnclave() throws {
        try #require(SecureEnclaveSSHKey.isAvailable, "this machine has no Secure Enclave")
    }

    @Test("A key generated in the enclave logs in to OpenSSH")
    func enclaveKeyAuthenticates() async throws {
        try requireEnclave()

        let handle = try SecureEnclaveSSHKey.generate(
            accessPolicy: .deviceUnlocked,
            comment: "se-test@apexterminal"
        )
        // Only the public half reaches the server, exactly as a person would paste it.
        let server = try OpenSSHTestServer(extraAuthorizedKeys: [handle.publicKeyOpenSSH])
        defer { server.shutDown() }

        let material = try SecureEnclaveSSHKey.material(
            blob: handle.blob,
            comment: "se-test@apexterminal",
            authenticationPrompt: nil
        )
        let connection = try await connect(to: server, credentials: [.privateKey(material)])
        let result = try await connection.execute(command: "printf ENCLAVE_OK")
        #expect(result.standardOutputText == "ENCLAVE_OK")
        await connection.close()

        // sshd names the key it accepted. Asserting on its own log removes the last way
        // this test could pass while proving something else: the fingerprint in the line
        // is the enclave key's, and no other credential was offered.
        let log = server.log()
        #expect(
            log.contains("Accepted publickey") && log.contains(handle.fingerprintSHA256),
            "sshd did not record accepting this key:\n\(log)"
        )
        #expect(log.contains("ECDSA \(handle.fingerprintSHA256)"), "sshd said:\n\(log)")
    }

    @Test("The same key is refused by a server that has not been given its public half")
    func enclaveKeyIsNotUniversallyAccepted() async throws {
        try requireEnclave()

        let handle = try SecureEnclaveSSHKey.generate(accessPolicy: .deviceUnlocked, comment: "se-test")
        // No `extraAuthorizedKeys`: the server knows nothing about this key. Without this
        // test the one above could pass for reasons that have nothing to do with the key.
        let server = try OpenSSHTestServer()
        defer { server.shutDown() }

        let material = try SecureEnclaveSSHKey.material(blob: handle.blob, comment: nil, authenticationPrompt: nil)
        var caught: Error?
        do {
            let connection = try await connect(to: server, credentials: [.privateKey(material)])
            await connection.close()
        } catch {
            caught = error
        }
        #expect(caught != nil)
    }

    @Test("The key announces itself as ecdsa-sha2-nistp256, which is what servers accept")
    func algorithmIsTheOneSecureEnclaveSupports() throws {
        try requireEnclave()

        let handle = try SecureEnclaveSSHKey.generate(accessPolicy: .deviceUnlocked, comment: "c")
        #expect(handle.publicKey.algorithm == "ecdsa-sha2-nistp256")
        #expect(handle.publicKeyOpenSSH.hasPrefix("ecdsa-sha2-nistp256 "))
        #expect(handle.publicKeyOpenSSH.hasSuffix(" c"))
        #expect(handle.fingerprintSHA256.hasPrefix("SHA256:"))

        let material = try SecureEnclaveSSHKey.material(blob: handle.blob, comment: nil, authenticationPrompt: nil)
        #expect(material.algorithm == "ecdsa-sha2-nistp256")
        // The public key derived from the restored handle must be the one on the server,
        // or a key that works today would stop working after a restart.
        #expect(material.publicKey == handle.publicKey)
    }

    @Test("`ssh-keygen` reads the public key the app writes, and agrees on its fingerprint")
    func publicKeyIsWhatOpenSSHThinksItIs() throws {
        try requireEnclave()

        let handle = try SecureEnclaveSSHKey.generate(accessPolicy: .deviceUnlocked, comment: "se@apexterminal")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("st-se-\(UUID().uuidString).pub")
        try (handle.publicKeyOpenSSH + "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-l", "-f", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        process.waitUntilExit()

        #expect(process.terminationStatus == 0, "ssh-keygen could not read the key: \(output)")
        // `ssh-keygen -l` prints "<bits> SHA256:… comment (ECDSA)".
        #expect(output.contains(handle.fingerprintSHA256), "ssh-keygen said \(output)")
        #expect(output.contains("(ECDSA)"))
    }

    @Test("A reference from another device is refused rather than half-working")
    func aForeignReferenceIsUnusable() throws {
        try requireEnclave()

        // Not a real reference: this is what a restored backup or a copied file would
        // give the app, and it must fail at the point of use with an error that says the
        // key cannot be moved.
        var caught: Error?
        do {
            _ = try SecureEnclaveSSHKey.material(
                blob: Data(repeating: 0x41, count: 143),
                comment: nil,
                authenticationPrompt: nil
            )
        } catch {
            caught = error
        }
        let failure = try #require(caught as? SecureEnclaveKeyError)
        guard case .unusable = failure else {
            Issue.record("expected .unusable, got \(failure)")
            return
        }
        #expect(failure.stError.recoverySuggestion?.contains("cannot be restored") == true)
    }

    @Test("Every way this can fail says what to do about it")
    func everyFailureCarriesARecoveryAction() {
        // A bare error code helps nobody, and these are all reachable: no enclave, no
        // biometrics, a refused creation, a key from another device.
        let failures: [SecureEnclaveKeyError] = [
            .unavailable,
            .biometricsUnavailable,
            .accessControlRejected("x"),
            .creationFailed("x"),
            .unusable("x"),
            .authenticationCancelled,
            .authenticationFailed("x"),
        ]
        for failure in failures {
            let error = failure.stError
            #expect(!error.message.isEmpty, "\(failure) has no message")
            #expect(error.recoverySuggestion?.isEmpty == false, "\(failure) has no recovery action")
        }
    }

    @Test("Biometric policies are the ones that need a person; device-unlocked is not")
    func unattendedUseIsDecidedByPolicy() {
        #expect(SecureEnclaveSSHKey.AccessPolicy.deviceUnlocked.worksUnattended)
        #expect(!SecureEnclaveSSHKey.AccessPolicy.biometricsEachUse.worksUnattended)
    }

    @Test("A cancelled biometric check is reported as a cancellation, not as a failure")
    func cancellationIsItsOwnCategory() {
        // `authenticatedContext` itself is deliberately not called here: on a Mac with
        // Touch ID it would raise a real prompt and stop the suite until somebody touched
        // the sensor. What it produces on cancellation is checked instead, because the
        // difference matters — a cancellation must not be shown as an error.
        #expect(SecureEnclaveKeyError.authenticationCancelled.stError.category == .cancelled)
        #expect(SecureEnclaveKeyError.authenticationFailed("x").stError.category == .credential)
    }

    private func connect(
        to server: OpenSSHTestServer,
        credentials: [SSHCredential]
    ) async throws -> SSHConnection {
        let identity = KnownHostIdentity(host: "127.0.0.1", port: server.fixtures.port)
        return try await SSHConnection.connect(
            transport: DirectTCPTransport(endpoint: TransportEndpoint(host: "127.0.0.1", port: server.fixtures.port)),
            configuration: SSHConnectionConfiguration(
                username: server.fixtures.username,
                credentials: credentials,
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
}
