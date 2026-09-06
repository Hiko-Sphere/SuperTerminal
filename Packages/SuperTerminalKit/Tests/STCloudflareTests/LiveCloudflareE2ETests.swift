import Foundation
import NIOTransportServices
import STCloudflare
import STCore
import STSSH
import STTerminal
import STTestSupport
import Testing

/// The live end-to-end run: a real Cloudflare Tunnel, a real Access application, and a
/// real SSH server on the other side.
///
/// This is the only thing that can substantiate the product's central claim. Everything
/// else in the suite tests the pieces; this tests that the pieces, Cloudflare and a real
/// server agree.
///
/// The suite is skipped when the environment is not configured, so a developer without a
/// Cloudflare account gets a clean run rather than a failure they cannot act on. When it
/// *is* configured, nothing is lenient: every step must succeed.
///
/// Configure it with the variables listed in `scripts/live-e2e.sh`.
@Suite(
    "Live Cloudflare end-to-end",
    .enabled(if: LiveEnvironment.fromEnvironment() != nil, "set ST_LIVE_CF_HOSTNAME to run"),
    .serialized
)
struct LiveCloudflareE2ETests {
    private var environment: LiveEnvironment {
        get throws {
            guard let environment = LiveEnvironment.fromEnvironment() else {
                throw LiveConfigurationMissing()
            }
            return environment
        }
    }

    struct LiveConfigurationMissing: Error, CustomStringConvertible {
        var description: String { "the live environment is not configured" }
    }

    struct LiveConfigurationInvalid: Error, CustomStringConvertible {
        let detail: String
        var description: String { "live configuration problem: \(detail)" }
    }

    private func credentials(_ environment: LiveEnvironment) throws -> [SSHCredential] {
        if let pem = environment.privateKeyPEM {
            let key = try OpenSSHPrivateKeyParser.parse(
                pem: pem,
                passphrase: environment.privateKeyPassphrase
            )
            return [.privateKey(key)]
        }
        if let password = environment.password {
            return [.password(Redacted(password, label: "ssh-password"))]
        }
        throw LiveConfigurationInvalid(detail: "no SSH credential was provided")
    }

    private func accessCredential(_ environment: LiveEnvironment) throws -> AccessCredential {
        guard let id = environment.serviceTokenID, let secret = environment.serviceTokenSecret else {
            throw LiveConfigurationInvalid(
                detail: "a service token is required for the automated run; the interactive login is exercised from the app"
            )
        }
        return .serviceToken(AccessServiceToken(clientID: id, clientSecret: secret))
    }

    @Test("The hostname is discovered as a Cloudflare Access application")
    func discoversAccessApplication() async throws {
        let environment = try environment
        let http = URLSessionHTTPTransport(userAgent: "SuperTerminal-live-test")
        let discovery = AccessDiscovery(http: http, jwks: JWKSProvider(http: http))

        let probe = try await discovery.probe(host: environment.hostname)
        guard case let .protected(appInfo) = probe else {
            Issue.record("\(environment.hostname) is not behind a Cloudflare Access application")
            return
        }
        // The auth domain is the trust anchor for the whole flow; it must be a
        // Cloudflare-hosted team domain and nothing else.
        #expect(appInfo.authDomain.hasSuffix(AccessDiscovery.authDomainSuffix))
        #expect(!appInfo.appAUD.isEmpty)
    }

    @Test("A service token opens the carrier and reaches a real interactive PTY")
    func serviceTokenReachesInteractivePTY() async throws {
        let environment = try environment
        let group = NIOTSEventLoopGroup.singleton

        let identity = KnownHostIdentity(
            host: environment.hostname,
            port: 443,
            jumpDestination: environment.jumpDestination
        )
        // Pin the fingerprint when one was supplied; otherwise trust on first use, which
        // is what a person would do on a first connection.
        let approval: any HostKeyApprovalDelegate = environment.expectedHostKeyFingerprint
            .map { PinnedFingerprintApproval(expectedFingerprint: $0) } ?? TrustOnFirstUseApproval()

        let connection = try await SSHConnection.connect(
            transport: CloudflareCarrierTransport(
                configuration: .init(
                    host: environment.hostname,
                    jumpDestination: environment.jumpDestination,
                    userAgent: "SuperTerminal-live-test"
                ),
                credential: try accessCredential(environment)
            ),
            configuration: SSHConnectionConfiguration(
                username: environment.username,
                credentials: try credentials(environment),
                knownHostIdentity: identity
            ),
            hostKeyVerifier: HostKeyVerifier(
                identity: identity,
                store: InMemoryKnownHostsStore(),
                approval: approval
            ),
            eventLoop: group.next()
        )

        // A real command on the real remote host. Anything short of this — a successful
        // upgrade, a completed handshake — would not prove a usable session.
        let result = try await connection.execute(command: "printf 'CF_E2E_OK\\n'; uname -sm")
        #expect(result.standardOutputText.contains("CF_E2E_OK"))
        #expect(result.exitStatus == 0)

        // And a genuinely interactive PTY, not just an exec channel.
        let shell = try await connection.openShell(size: TerminalSize(columns: 100, rows: 30))
        try await shell.send("stty size\n")

        let output = shell.output
        let sawGeometry = try await withTimeout(seconds: 30) { () -> Bool in
            // The emulator lives inside the closure so it is never shared across
            // isolation domains; the screen it renders is what proves a PTY was
            // allocated with the geometry we asked for.
            var emulator = TerminalEmulator(columns: 100, rows: 30, scrollbackLimit: 500)
            for await event in output {
                if case let .output(data) = event {
                    _ = emulator.feed(data)
                    _ = emulator.flush()
                    if emulator.activeScreen.visibleText.contains("30 100") { return true }
                }
                if case .closed = event { return false }
            }
            return false
        }
        #expect(sawGeometry, "the remote PTY should report the geometry we requested")

        await shell.close()
        await connection.close()
    }

    @Test("A token for the wrong audience is refused")
    func wrongAudienceIsRefused() async throws {
        let environment = try environment
        let group = NIOTSEventLoopGroup.singleton

        // A service token with a valid-looking but incorrect secret must be refused by
        // the edge, not merely fail later during SSH.
        let transport = CloudflareCarrierTransport(
            configuration: .init(host: environment.hostname, userAgent: "SuperTerminal-live-test"),
            credential: .serviceToken(
                AccessServiceToken(
                    clientID: environment.serviceTokenID ?? "unknown.access",
                    clientSecret: String(repeating: "0", count: 64)
                )
            )
        )
        var caught: STError?
        do {
            _ = try await transport.connect(on: group.next())
        } catch let error as STError {
            caught = error
        }
        #expect(caught?.category == .access)
    }

    @Test("An unauthenticated connection is refused rather than silently allowed")
    func unauthenticatedIsRefused() async throws {
        let environment = try environment
        let group = NIOTSEventLoopGroup.singleton

        let transport = CloudflareCarrierTransport(
            configuration: .init(host: environment.hostname, userAgent: "SuperTerminal-live-test"),
            credential: .none
        )
        var caught: STError?
        do {
            _ = try await transport.connect(on: group.next())
        } catch let error as STError {
            caught = error
        }
        #expect(caught?.category == .access, "an Access-protected host must not accept an unauthenticated carrier")
    }
}
