import Crypto
import Foundation
import NIOSSH
import NIOTransportServices
import STCloudflare
import STCore
import STSSH
import STTestSupport
import Testing
import _CryptoExtras

/// RSA support, proved against OpenSSH rather than against itself.
///
/// The change that makes RSA work separates a key's blob identifier (`ssh-rsa`) from its
/// negotiated algorithm name (`rsa-sha2-256` / `rsa-sha2-512`), which RFC 8332 makes
/// different for RSA alone. Everything here exists because that separation is easy to get
/// subtly wrong in a way that either fails to interoperate or, worse, accepts something it
/// should not.
@Suite("RSA interoperability", .serialized)
struct RSAInteropTests {
    private func connect(
        to server: OpenSSHTestServer,
        credentials: [SSHCredential],
        group: NIOTSEventLoopGroup
    ) async throws -> SSHConnection {
        let identity = KnownHostIdentity(host: "127.0.0.1", port: server.fixtures.port)
        return try await SSHConnection.connect(
            transport: DirectTCPTransport(
                endpoint: TransportEndpoint(host: "127.0.0.1", port: server.fixtures.port)
            ),
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
            eventLoop: group.next()
        )
    }

    @Test("An RSA user key authenticates against a real sshd")
    func rsaUserKeyAuthenticates() async throws {
        let server = try OpenSSHTestServer()
        let group = NIOTSEventLoopGroup.singleton
        defer { server.shutDown() }

        do {
            let key = try OpenSSHPrivateKeyParser.parse(pem: server.fixtures.clientRSAPrivateKeyPEM)
            #expect(key.algorithm == "ssh-rsa")
            // The public half must still be spelled `ssh-rsa`, whatever algorithm is
            // negotiated — this is the distinction the whole change rests on.
            #expect(key.publicKey.algorithm == "ssh-rsa")

            let connection = try await connect(to: server, credentials: [.privateKey(key)], group: group)
            let result = try await connection.execute(command: "printf 'RSA_USER_KEY_%s\\n' OK")
            await connection.close()
            #expect(result.standardOutputText == "RSA_USER_KEY_OK\n")
        } catch {
            throw error
        }
    }

    @Test("A server offering only an RSA host key can be reached")
    func rsaOnlyHostKeyIsAccepted() async throws {
        // No Ed25519 and no ECDSA host key exists on this server, so a successful
        // connection can only have gone through RSA host key verification.
        let server = try OpenSSHTestServer(hostKeyAlgorithms: [.rsa])
        let group = NIOTSEventLoopGroup.singleton
        defer { server.shutDown() }

        do {
            let key = try OpenSSHPrivateKeyParser.parse(pem: server.fixtures.clientPrivateKeyPEM)
            let store = InMemoryKnownHostsStore()
            let identity = KnownHostIdentity(host: "127.0.0.1", port: server.fixtures.port)
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
                    store: store,
                    approval: TrustOnFirstUseApproval()
                ),
                eventLoop: group.next()
            )
            let result = try await connection.execute(command: "printf 'RSA_HOST_KEY_%s\\n' OK")
            await connection.close()

            #expect(result.standardOutputText == "RSA_HOST_KEY_OK\n")
            // And the key we remembered is the server's real RSA host key.
            let remembered = try await store.entry(for: identity)
            #expect(remembered?.key.algorithm == "ssh-rsa")
            #expect(remembered?.key == (try SSHHostKey(openSSHLine: server.hostKeyOpenSSHLine)))
        } catch {
            throw error
        }
    }

    @Test("An RSA key authenticates over the Cloudflare carrier too")
    func rsaWorksOverTheCarrier() async throws {
        // The carrier is just a byte stream, so this should hold — but "should" is how
        // transport-specific bugs survive.
        let ssh = try OpenSSHTestServer()
        let carrier = try WebSocketCarrierTestServer(configuration: .init(originPort: ssh.fixtures.port))
        let group = NIOTSEventLoopGroup.singleton
        defer {
            carrier.shutDown()
            ssh.shutDown()
        }

        do {
            let key = try OpenSSHPrivateKeyParser.parse(pem: ssh.fixtures.clientRSAPrivateKeyPEM)
            let identity = KnownHostIdentity(host: "127.0.0.1", port: carrier.port)
            let connection = try await SSHConnection.connect(
                transport: CloudflareCarrierTransport(
                    configuration: .init(
                        host: "127.0.0.1",
                        port: carrier.port,
                        userAgent: "SuperTerminal/test",
                        security: .plaintextLoopbackOnly
                    ),
                    credential: .none
                ),
                configuration: SSHConnectionConfiguration(
                    username: ssh.fixtures.username,
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
            let result = try await connection.execute(command: "printf 'RSA_CARRIER_%s\\n' OK")
            await connection.close()
            #expect(result.standardOutputText == "RSA_CARRIER_OK\n")
        } catch {
            throw error
        }
    }

    @Test("ssh-keygen and this parser agree on an RSA key's fingerprint")
    func fingerprintMatchesOpenSSH() throws {
        let server = try OpenSSHTestServer()
        defer { server.shutDown() }

        let parsed = try OpenSSHPrivateKeyParser.parse(pem: server.fixtures.clientRSAPrivateKeyPEM)
        let publicKeyLine = try String(
            contentsOf: server.fixtures.root.appendingPathComponent("client_rsa.pub"),
            encoding: .utf8
        )
        let expected = try SSHHostKey(openSSHLine: publicKeyLine)
        // A mismatch here would mean the modulus or exponent was decoded wrongly — the
        // e-before-n ordering is exactly the kind of thing that produces a key that looks
        // plausible and is not the user's.
        #expect(parsed.publicKey == expected)
        #expect(parsed.publicKey.fingerprintSHA256 == expected.fingerprintSHA256)
    }

    // MARK: - Adversarial cases

    @Test("A signature claiming the wrong RSA algorithm does not verify")
    func mismatchedAlgorithmIsRejected() throws {
        let privateKey = try _RSA.Signing.PrivateKey(keySize: .bits2048)
        let nioPrivate = NIOSSHPrivateKey(rsaKey: privateKey)
        let publicKey = nioPrivate.publicKey

        let payload = Data("some bytes to sign".utf8)
        let sha256Signature = try NIOSSHRSASignatureAlgorithm.sha256.signature(for: payload, using: privateKey)

        // Correct pairing verifies.
        #expect(
            NIOSSHRSASignatureAlgorithm.sha256.isValidSignature(sha256Signature, for: payload, using: privateKey.publicKey)
        )
        // The same bytes checked against the other digest must not. If the algorithm were
        // taken from the key rather than from the signature, this would pass.
        #expect(
            !NIOSSHRSASignatureAlgorithm.sha512.isValidSignature(sha256Signature, for: payload, using: privateKey.publicKey)
        )
        #expect(publicKey.algorithmNamesForTesting.contains("rsa-sha2-512"))
        #expect(publicKey.algorithmNamesForTesting.contains("rsa-sha2-256"))
    }

    @Test("An RSA key does not accept a non-RSA algorithm name")
    func nonRSAAlgorithmIsRejectedForRSAKey() throws {
        let privateKey = try _RSA.Signing.PrivateKey(keySize: .bits2048)
        let publicKey = NIOSSHPrivateKey(rsaKey: privateKey).publicKey
        #expect(!publicKey.supportsSignatureAlgorithmForTesting("ssh-ed25519"))
        // `ssh-rsa` names SHA-1, which this library refuses to sign or verify, so it must
        // not be accepted as a negotiated algorithm even though it is the blob's name.
        #expect(!publicKey.supportsSignatureAlgorithmForTesting("ssh-rsa"))
    }

    @Test("An Ed25519 key does not accept an RSA algorithm name")
    func rsaAlgorithmIsRejectedForEd25519Key() throws {
        let publicKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
        #expect(!publicKey.supportsSignatureAlgorithmForTesting("rsa-sha2-512"))
        #expect(publicKey.supportsSignatureAlgorithmForTesting("ssh-ed25519"))
    }

    @Test("A tampered RSA signature does not verify")
    func tamperedSignatureIsRejected() throws {
        let privateKey = try _RSA.Signing.PrivateKey(keySize: .bits2048)
        let payload = Data("authentic payload".utf8)
        var signature = try NIOSSHRSASignatureAlgorithm.sha512.signature(for: payload, using: privateKey)
        #expect(
            NIOSSHRSASignatureAlgorithm.sha512.isValidSignature(signature, for: payload, using: privateKey.publicKey)
        )

        signature[signature.startIndex] ^= 0xFF
        #expect(
            !NIOSSHRSASignatureAlgorithm.sha512.isValidSignature(signature, for: payload, using: privateKey.publicKey)
        )
    }

    @Test("A signature over different bytes does not verify")
    func signatureIsBoundToItsPayload() throws {
        let privateKey = try _RSA.Signing.PrivateKey(keySize: .bits2048)
        let signature = try NIOSSHRSASignatureAlgorithm.sha512.signature(
            for: Data("payload one".utf8),
            using: privateKey
        )
        #expect(
            !NIOSSHRSASignatureAlgorithm.sha512.isValidSignature(
                signature,
                for: Data("payload two".utf8),
                using: privateKey.publicKey
            )
        )
    }
}
