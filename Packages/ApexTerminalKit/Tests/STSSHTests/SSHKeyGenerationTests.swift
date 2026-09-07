import Foundation
import NIOTransportServices
import STCore
import Testing
@testable import STSSH
@testable import STTestSupport

/// Keys generated on the device must be usable everywhere, not just here.
///
/// The strongest check is interoperability: `ssh-keygen` reads the private key and agrees
/// on its fingerprint, and a real `sshd` accepts it for authentication. A key format only
/// this app understands would make the app a place keys go to be trapped.
@Suite("SSH key generation", .serialized)
struct SSHKeyGenerationTests {
    @Test("A generated key round-trips through this app's own parser", arguments: SSHKeyAlgorithm.allCases)
    func roundTripsThroughOurParser(algorithm: SSHKeyAlgorithm) throws {
        let generated = try SSHKeyGenerator.generate(algorithm: algorithm, comment: "roundtrip@test")
        let parsed = try OpenSSHPrivateKeyParser.parse(pem: generated.privateKeyPEM)
        #expect(parsed.algorithm == algorithm.sshName)
        #expect(parsed.publicKey.fingerprintSHA256 == generated.fingerprintSHA256)
        #expect(parsed.comment == "roundtrip@test")
    }

    @Test("ssh-keygen reads the private key and agrees on the fingerprint", arguments: SSHKeyAlgorithm.allCases)
    func openSSHAgrees(algorithm: SSHKeyAlgorithm) throws {
        let generated = try SSHKeyGenerator.generate(algorithm: algorithm, comment: "interop@test")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("st-keygen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let keyURL = directory.appendingPathComponent("id_test")
        try generated.privateKeyPEM.write(to: keyURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)

        // `ssh-keygen -y` derives the public key from the private one. It only succeeds if
        // the container, the key type and the key material are all correct.
        let derived = try run("/usr/bin/ssh-keygen", ["-y", "-f", keyURL.path])
        #expect(
            derived.hasPrefix(algorithm.sshName),
            "ssh-keygen derived: \(derived.prefix(60))"
        )

        // And it must agree on the fingerprint the app shows the user.
        let listed = try run("/usr/bin/ssh-keygen", ["-l", "-f", keyURL.path])
        #expect(
            listed.contains(generated.fingerprintSHA256),
            "ssh-keygen reported \(listed), app shows \(generated.fingerprintSHA256)"
        )
    }

    @Test("A generated key authenticates against a real sshd", arguments: SSHKeyAlgorithm.allCases)
    func authenticatesAgainstRealServer(algorithm: SSHKeyAlgorithm) async throws {
        let generated = try SSHKeyGenerator.generate(algorithm: algorithm, comment: "auth@test")
        // The server trusts only this generated key, so a pass means the key really works
        // rather than some other credential having been picked up.
        let server = try OpenSSHTestServer(extraAuthorizedKeys: [generated.publicKeyOpenSSH])
        defer { server.shutDown() }

        let group = NIOTSEventLoopGroup.singleton
        let key = try OpenSSHPrivateKeyParser.parse(pem: generated.privateKeyPEM)
        let identity = KnownHostIdentity(host: "127.0.0.1", port: server.fixtures.port)

        do {
            let connection = try await SSHConnection.connect(
                transport: DirectTCPTransport(
                    endpoint: TransportEndpoint(host: "127.0.0.1", port: server.fixtures.port)
                ),
                configuration: SSHConnectionConfiguration(
                    username: server.fixtures.username,
                    credentials: [.privateKey(key)],
                    knownHostIdentity: identity
                ),
                hostKeyVerifier: HostKeyVerifier(
                    identity: identity,
                    store: InMemoryKnownHostsStore(),
                    approval: TrustOnFirstUseApproval()
                ),
                eventLoop: group.next()
            )
            let result = try await connection.execute(command: "printf 'GENERATED_KEY_%s\\n' OK")
            await connection.close()
            #expect(result.standardOutputText == "GENERATED_KEY_OK\n")
        } catch {
            throw error
        }
    }

    @Test("Two generated keys are different")
    func keysAreNotReused() throws {
        let first = try SSHKeyGenerator.generate(algorithm: .ed25519, comment: "a")
        let second = try SSHKeyGenerator.generate(algorithm: .ed25519, comment: "a")
        #expect(first.fingerprintSHA256 != second.fingerprintSHA256)
        #expect(first.privateKeyPEM != second.privateKeyPEM)
    }

    @Test("The public key line is in authorized_keys form")
    func publicKeyLineIsUsable() throws {
        let generated = try SSHKeyGenerator.generate(algorithm: .ed25519, comment: "phone@apexterminal")
        let fields = generated.publicKeyOpenSSH.split(separator: " ")
        #expect(fields.count == 3)
        #expect(fields[0] == "ssh-ed25519")
        #expect(Data(base64Encoded: String(fields[1])) != nil)
        #expect(fields[2] == "phone@apexterminal")
    }

    private func run(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
