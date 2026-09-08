import Foundation
import NIOTransportServices
import NIOSSH
import STCore
@testable import STSSH
import STTestSupport
import Testing

/// OpenSSH certificates, against a real sshd that has been told to trust an authority
/// (D-046).
///
/// The key these tests authenticate with is deliberately absent from `authorized_keys`.
/// A login that succeeds with it succeeded because the server checked a certificate, and
/// there is no other explanation available.
@Suite("OpenSSH certificates against real OpenSSH", .serialized)
struct CertificateTests {
    private func connect(
        to server: OpenSSHTestServer,
        credentials: [SSHCredential],
        authorities: [SSHCertificateAuthority] = [],
        approval: any HostKeyApprovalDelegate = TrustOnFirstUseApproval()
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
                approval: approval,
                certificateAuthorities: authorities
            ),
            eventLoop: NIOTSEventLoopGroup.singleton.next()
        )
    }

    private func certifiedCredential(_ server: OpenSSHTestServer) throws -> SSHCredential {
        .certifiedKey(
            try OpenSSHPrivateKeyParser.parse(pem: server.fixtures.certifiedClientPrivateKeyPEM),
            try SSHCertificate(openSSHRepresentation: server.fixtures.clientCertificateOpenSSH)
        )
    }

    // MARK: - User certificates

    @Test("A key the server has never heard of gets in on its certificate")
    func userCertificateAuthenticates() async throws {
        let server = try OpenSSHTestServer(certificateOptions: .init(trustsAuthority: true))
        defer { server.shutDown() }

        let connection = try await connect(to: server, credentials: [try certifiedCredential(server)])
        let result = try await connection.execute(command: "printf CERT_OK")
        #expect(result.standardOutputText == "CERT_OK")
        await connection.close()
    }

    @Test("Without the certificate the same key is refused, which is what makes the last test mean something")
    func bareKeyIsRefused() async throws {
        let server = try OpenSSHTestServer(certificateOptions: .init(trustsAuthority: true))
        defer { server.shutDown() }

        var caught: Error?
        do {
            let bare = SSHCredential.privateKey(
                try OpenSSHPrivateKeyParser.parse(pem: server.fixtures.certifiedClientPrivateKeyPEM)
            )
            let connection = try await connect(to: server, credentials: [bare])
            await connection.close()
        } catch {
            caught = error
        }
        #expect(caught != nil, "a key that is in no authorized_keys file must not get in on its own")
    }

    @Test("A certificate the server's authority did not sign is refused")
    func untrustedAuthorityIsRefused() async throws {
        // The server trusts nobody: the certificate is well-formed and current, and still
        // gets nowhere, because trust comes from the server's configuration.
        let server = try OpenSSHTestServer(certificateOptions: .init(trustsAuthority: false))
        defer { server.shutDown() }

        var caught: Error?
        do {
            let connection = try await connect(to: server, credentials: [try certifiedCredential(server)])
            await connection.close()
        } catch {
            caught = error
        }
        #expect(caught != nil)
    }

    @Test("A certificate issued for another user is refused by the server")
    func wrongPrincipalIsRefused() async throws {
        let server = try OpenSSHTestServer(
            certificateOptions: .init(trustsAuthority: true, userPrincipal: "somebody-else")
        )
        defer { server.shutDown() }

        var caught: Error?
        do {
            let connection = try await connect(to: server, credentials: [try certifiedCredential(server)])
            await connection.close()
        } catch {
            caught = error
        }
        #expect(caught != nil, "the principal is the whole point of a certificate")
    }

    @Test("An expired certificate is refused")
    func expiredCertificateIsRefused() async throws {
        let server = try OpenSSHTestServer(
            certificateOptions: .init(trustsAuthority: true, validity: "-2h:-1h")
        )
        defer { server.shutDown() }

        // The app can see it is expired without asking the server, which is the difference
        // between "your certificate ran out on Tuesday" and "permission denied".
        let certificate = try SSHCertificate(openSSHRepresentation: server.fixtures.clientCertificateOpenSSH)
        #expect(!certificate.isValid(), "the certificate should be past its window")

        var caught: Error?
        do {
            let connection = try await connect(to: server, credentials: [try certifiedCredential(server)])
            await connection.close()
        } catch {
            caught = error
        }
        #expect(caught != nil)
    }

    @Test("A certificate says who issued it, who it speaks for, and until when")
    func certificateReadsItsOwnFields() async throws {
        let server = try OpenSSHTestServer(
            certificateOptions: .init(trustsAuthority: true, keyID: "issued-for-a-test")
        )
        defer { server.shutDown() }

        let certificate = try SSHCertificate(openSSHRepresentation: server.fixtures.clientCertificateOpenSSH)
        #expect(certificate.kind == .user)
        #expect(certificate.keyID == "issued-for-a-test")
        #expect(certificate.principals == [server.fixtures.username])
        #expect(certificate.permits(principal: server.fixtures.username))
        #expect(!certificate.permits(principal: "root"))
        #expect(certificate.isValid())
        #expect(certificate.validBefore != nil, "ssh-keygen was given a window, so there is an end date")

        // The authority's fingerprint is the thing a person compares against what the CA's
        // owner published, so it has to match what `ssh-keygen -l` would print for it.
        let authority = SSHCertificateAuthority(
            name: "test", openSSHPublicKey: server.fixtures.certificateAuthorityPublicKey, hostPatterns: ["*"]
        )
        #expect(certificate.authorityFingerprintSHA256 == authority.fingerprintSHA256)
        #expect(!authority.fingerprintSHA256.isEmpty)
    }

    // MARK: - Host certificates

    @Test("A server whose host key is certified by a trusted authority needs no fingerprint")
    func hostCertificateIsAcceptedWithoutAsking() async throws {
        let server = try OpenSSHTestServer(
            hostKeyAlgorithms: [.ed25519],
            certificateOptions: .init(trustsAuthority: true, presentsHostCertificate: true)
        )
        defer { server.shutDown() }

        let authority = SSHCertificateAuthority(
            name: "test authority",
            openSSHPublicKey: server.fixtures.certificateAuthorityPublicKey,
            hostPatterns: ["127.0.0.1"]
        )
        // An approval delegate that fails the test if it is consulted: the certificate is
        // supposed to answer the question on its own.
        let connection = try await connect(
            to: server,
            credentials: [try certifiedCredential(server)],
            authorities: [authority],
            approval: RefuseToBeAsked()
        )
        let result = try await connection.execute(command: "printf HOSTCERT_OK")
        #expect(result.standardOutputText == "HOSTCERT_OK")
        await connection.close()
    }

    @Test("A host certificate from an authority this device does not trust falls back to the fingerprint")
    func untrustedHostAuthorityFallsBack() async throws {
        let server = try OpenSSHTestServer(
            hostKeyAlgorithms: [.ed25519],
            certificateOptions: .init(trustsAuthority: true, presentsHostCertificate: true)
        )
        defer { server.shutDown() }

        // No authorities at all: the connection still succeeds, because the ordinary
        // trust-on-first-use path is asked, which is what a client without certificate
        // configuration should do.
        let asked = RecordingApproval()
        let connection = try await connect(
            to: server,
            credentials: [try certifiedCredential(server)],
            authorities: [],
            approval: asked
        )
        #expect(asked.wasAsked, "with no trusted authority the user has to be asked")
        await connection.close()
    }

    @Test("Falling back remembers the key inside the certificate, not the certificate")
    func fallbackRemembersTheBareKey() async throws {
        let server = try OpenSSHTestServer(
            hostKeyAlgorithms: [.ed25519],
            certificateOptions: .init(trustsAuthority: true, presentsHostCertificate: true)
        )
        defer { server.shutDown() }

        let store = InMemoryKnownHostsStore()
        let identity = KnownHostIdentity(host: "127.0.0.1", port: server.fixtures.port)
        let connection = try await SSHConnection.connect(
            transport: DirectTCPTransport(endpoint: TransportEndpoint(host: "127.0.0.1", port: server.fixtures.port)),
            configuration: SSHConnectionConfiguration(
                username: server.fixtures.username,
                credentials: [try certifiedCredential(server)],
                knownHostIdentity: identity
            ),
            hostKeyVerifier: HostKeyVerifier(
                identity: identity, store: store, approval: TrustOnFirstUseApproval()
            ),
            eventLoop: NIOTSEventLoopGroup.singleton.next()
        )
        await connection.close()

        // What was remembered is the server's own host key, the one `ssh-keygen -l` would
        // print for `host_ed25519.pub` — not the certificate, which is reissued routinely
        // and would make every renewal look like a rekeyed server.
        let entry = try #require(try await store.entry(for: identity))
        let bare = try SSHHostKey(NIOSSHPublicKey(openSSHPublicKey: server.fixtures.hostKeyOpenSSH))
        #expect(entry.key.fingerprintSHA256 == bare.fingerprintSHA256)
        #expect(!server.fixtures.hostCertificateOpenSSH.isEmpty, "the server really did present a certificate")
    }

    @Test("A host certificate for a different host name is refused outright, not turned into a prompt")
    func hostCertificateForAnotherNameIsRefused() async throws {
        let server = try OpenSSHTestServer(
            hostKeyAlgorithms: [.ed25519],
            certificateOptions: .init(
                trustsAuthority: true,
                presentsHostCertificate: true,
                hostPrincipal: "somewhere.else.example"
            )
        )
        defer { server.shutDown() }

        let authority = SSHCertificateAuthority(
            name: "test authority",
            openSSHPublicKey: server.fixtures.certificateAuthorityPublicKey,
            hostPatterns: ["127.0.0.1"]
        )
        let asked = RecordingApproval()
        var caught: Error?
        do {
            let connection = try await connect(
                to: server,
                credentials: [try certifiedCredential(server)],
                authorities: [authority],
                approval: asked
            )
            await connection.close()
        } catch {
            caught = error
        }
        let failure = try #require(caught as? STError)
        #expect(failure.category == .hostKey)
        // The important half: a certificate that fails validation must not become a
        // question somebody taps through.
        #expect(!asked.wasAsked, "a refused certificate must not fall back to asking")
    }

    @Test("An authority is trusted only for the hosts its patterns match")
    func authorityPatternsAreNarrow() {
        let authority = SSHCertificateAuthority(
            name: "prod", openSSHPublicKey: "ssh-ed25519 AAAA", hostPatterns: ["*.prod.example", "bastion.example"]
        )
        #expect(authority.vouchesFor(host: "web1.prod.example"))
        #expect(authority.vouchesFor(host: "bastion.example"))
        #expect(!authority.vouchesFor(host: "web1.staging.example"))
        #expect(!authority.vouchesFor(host: "prod.example"))
        // Case is not significant in host names, and a pattern that only matched one
        // spelling would be a trap.
        #expect(authority.vouchesFor(host: "WEB1.PROD.EXAMPLE"))
    }

    @Test("The pattern language is OpenSSH's, and nothing more")
    func patternMatching() {
        #expect(SSHCertificateAuthority.matches(pattern: "*", host: "anything.at.all"))
        #expect(SSHCertificateAuthority.matches(pattern: "a?c", host: "abc"))
        #expect(!SSHCertificateAuthority.matches(pattern: "a?c", host: "abbc"))
        #expect(SSHCertificateAuthority.matches(pattern: "*.example.com", host: "a.b.example.com"))
        #expect(!SSHCertificateAuthority.matches(pattern: "*.example.com", host: "example.com"))
        #expect(SSHCertificateAuthority.matches(pattern: "host*", host: "host"))
        // A regular expression would read these as something else entirely, which is why
        // the matcher is written out rather than borrowed.
        #expect(!SSHCertificateAuthority.matches(pattern: "a.c", host: "abc"))
        #expect(!SSHCertificateAuthority.matches(pattern: "a+", host: "aaa"))
    }
}

/// Fails the test if it is consulted at all.
private struct RefuseToBeAsked: HostKeyApprovalDelegate {
    func approveUnknownHost(identity: KnownHostIdentity, key: SSHHostKey) async -> Bool {
        Issue.record("the user was asked about a host key that a certificate had already settled")
        return false
    }

    func approveChangedHost(identity: KnownHostIdentity, expected: SSHHostKey, presented: SSHHostKey) async -> Bool {
        Issue.record("the user was asked about a changed host key")
        return false
    }
}

/// Accepts, and remembers that it was asked.
private final class RecordingApproval: HostKeyApprovalDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var asked = false

    var wasAsked: Bool { lock.withLock { asked } }

    func approveUnknownHost(identity: KnownHostIdentity, key: SSHHostKey) async -> Bool {
        lock.withLock { asked = true }
        return true
    }

    func approveChangedHost(identity: KnownHostIdentity, expected: SSHHostKey, presented: SSHHostKey) async -> Bool {
        lock.withLock { asked = true }
        return false
    }
}
