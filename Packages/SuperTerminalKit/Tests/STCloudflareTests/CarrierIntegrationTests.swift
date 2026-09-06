import Foundation
import NIOCore
import NIOTransportServices
@testable import STCloudflare
import STCore
import STSSH
import STTestSupport
import Testing

/// Tests the Cloudflare carrier against a local server that speaks the same protocol as
/// the edge: an HTTP/1.1 WebSocket upgrade whose binary frames carry a raw byte stream.
///
/// These prove the *transport* is correct — the upgrade request shape, the Access
/// headers, masking, fragment handling, and a complete SSH session over the result.
/// They prove nothing about Cloudflare Access authentication, which no local harness
/// can; see `TEST_REPORT.md`.
@Suite("Cloudflare carrier", .serialized)
struct CarrierIntegrationTests {
    private func withHarness<T>(
        behaviour: WebSocketCarrierTestServer.Behaviour = .bridge,
        requiredAccessToken: String? = nil,
        requiredServiceToken: (id: String, secret: String)? = nil,
        _ body: (OpenSSHTestServer, WebSocketCarrierTestServer, NIOTSEventLoopGroup) async throws -> T
    ) async throws -> T {
        let ssh = try OpenSSHTestServer()
        let carrier = try WebSocketCarrierTestServer(
            configuration: .init(
                originPort: ssh.fixtures.port,
                requiredAccessToken: requiredAccessToken,
                requiredServiceToken: requiredServiceToken,
                behaviour: behaviour
            )
        )
        let group = NIOTSEventLoopGroup.singleton
        do {
            let result = try await body(ssh, carrier, group)
            carrier.shutDown()
            ssh.shutDown()
            return result
        } catch {
            carrier.shutDown()
            ssh.shutDown()
            throw error
        }
    }

    private func makeTransport(
        port: Int,
        credential: AccessCredential,
        jumpDestination: String? = nil
    ) -> CloudflareCarrierTransport {
        CloudflareCarrierTransport(
            configuration: .init(
                host: "127.0.0.1",
                port: port,
                jumpDestination: jumpDestination,
                userAgent: "SuperTerminal/test",
                pingInterval: .seconds(5),
                security: .plaintextLoopbackOnly
            ),
            credential: credential
        )
    }

    @Test("A full SSH session runs over the WebSocket carrier")
    func sshOverCarrier() async throws {
        try await withHarness { ssh, carrier, group in
            let key = try OpenSSHPrivateKeyParser.parse(pem: ssh.fixtures.clientPrivateKeyPEM)
            let identity = KnownHostIdentity(host: "127.0.0.1", port: carrier.port)
            let verifier = HostKeyVerifier(
                identity: identity,
                store: InMemoryKnownHostsStore(),
                approval: TrustOnFirstUseApproval()
            )

            let connection = try await SSHConnection.connect(
                transport: makeTransport(port: carrier.port, credential: .none),
                configuration: SSHConnectionConfiguration(
                    username: ssh.fixtures.username,
                    credentials: [.privateKey(key)],
                    knownHostIdentity: identity
                ),
                hostKeyVerifier: verifier,
                eventLoop: group.next()
            )
            let result = try await connection.execute(command: "printf 'CF_E2E_OK\\n'")
            await connection.close()

            #expect(result.standardOutputText == "CF_E2E_OK\n")
            #expect(result.exitStatus == 0)
        }
    }

    @Test("An interactive PTY works over the carrier and survives a large burst of output")
    func interactivePTYOverCarrier() async throws {
        try await withHarness { ssh, carrier, group in
            let key = try OpenSSHPrivateKeyParser.parse(pem: ssh.fixtures.clientPrivateKeyPEM)
            let identity = KnownHostIdentity(host: "127.0.0.1", port: carrier.port)
            let connection = try await SSHConnection.connect(
                transport: makeTransport(port: carrier.port, credential: .none),
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
            let shell = try await connection.openShell(size: TerminalSize(columns: 120, rows: 40))

            // ~256 KiB in one go, which forces the edge-side framing and the client's
            // fragment handling to carry far more than a single frame's worth.
            // The marker is assembled by the remote shell, so the terminal's echo of
            // the command line cannot contain it — otherwise the collector would stop
            // on the echo, before a single byte of the burst had arrived.
            try await shell.send("head -c 262144 /dev/zero | tr '\\0' 'x'; printf '\\nBURST_%s\\n' DONE\n")

            let output = shell.output
            let (bytes, sawMarker) = try await withTimeout(seconds: 45) { () -> (Int, Bool) in
                var bytes = 0
                var sawMarker = false
                // The marker is printed after the burst, so seeing it means every byte
                // in between arrived — the count is then a check on how many.
                for await event in output {
                    if case let .output(data) = event {
                        bytes += data.count
                        if String(decoding: data, as: UTF8.self).contains("BURST_DONE") {
                            sawMarker = true
                            return (bytes, true)
                        }
                    }
                    if case .closed = event { return (bytes, sawMarker) }
                }
                return (bytes, sawMarker)
            }
            await shell.close()
            await connection.close()

            #expect(sawMarker)
            #expect(bytes > 200_000)
        }
    }

    @Test("The Access token reaches the edge in the Cf-Access-Token header")
    func accessTokenHeaderIsSent() async throws {
        // The carrier server requires this exact value, so a pass means the header
        // genuinely arrived — not merely that the client intended to send it.
        let tokenValue = "test.access.token.value"
        try await withHarness(requiredAccessToken: tokenValue) { ssh, carrier, group in
            let key = try OpenSSHPrivateKeyParser.parse(pem: ssh.fixtures.clientPrivateKeyPEM)
            let identity = KnownHostIdentity(host: "127.0.0.1", port: carrier.port)
            let connection = try await SSHConnection.connect(
                transport: makeTransport(
                    port: carrier.port,
                    credential: .userToken(try Self.makeToken(value: tokenValue))
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
            let result = try await connection.execute(command: "printf 'ACCESS_TOKEN_OK\\n'")
            await connection.close()

            #expect(result.standardOutputText == "ACCESS_TOKEN_OK\n")
            #expect(carrier.observedUpgradeHeaders().last?.first(name: "Cf-Access-Token") == tokenValue)
        }
    }

    @Test("A token the edge does not accept is reported as an Access failure")
    func wrongAccessTokenIsRefused() async throws {
        try await withHarness(requiredAccessToken: "the-only-acceptable-token") { _, carrier, group in
            var caught: STError?
            do {
                _ = try await makeTransport(
                    port: carrier.port,
                    credential: .userToken(try Self.makeToken(value: "a-different-token"))
                ).connect(on: group.next())
            } catch let error as STError {
                caught = error
            }
            #expect(caught?.category == .access)
        }
    }

    /// Builds a `ValidatedAccessToken` directly, bypassing validation.
    ///
    /// These tests are about the *carrier*: whether the credential reaches the edge in
    /// the right header. Validation itself is covered separately in
    /// `AccessValidationTests`, so minting a token here keeps the two concerns from
    /// being tangled into one test that proves neither cleanly.
    static func makeToken(value: String) throws -> ValidatedAccessToken {
        let json = Data(#"{"aud":["test-aud"],"iss":"https://team.cloudflareaccess.com","exp":4102444800,"iat":1700000000}"#.utf8)
        let claims = try JSONDecoder().decode(AccessTokenClaims.self, from: json)
        return ValidatedAccessToken(
            token: value,
            claims: claims,
            appInfo: AccessAppInfo(
                authDomain: "team.cloudflareaccess.com",
                appAUD: "test-aud",
                appHostname: "127.0.0.1"
            )
        )
    }

    @Test("Service token headers are sent and accepted")
    func serviceTokenHeadersAreSent() async throws {
        let service = (id: "client-id-value", secret: "client-secret-value")
        try await withHarness(requiredServiceToken: service) { ssh, carrier, group in
            let key = try OpenSSHPrivateKeyParser.parse(pem: ssh.fixtures.clientPrivateKeyPEM)
            let identity = KnownHostIdentity(host: "127.0.0.1", port: carrier.port)
            let connection = try await SSHConnection.connect(
                transport: makeTransport(
                    port: carrier.port,
                    credential: .serviceToken(
                        AccessServiceToken(clientID: service.id, clientSecret: service.secret)
                    )
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
            let result = try await connection.execute(command: "printf 'SERVICE_TOKEN_OK\\n'")
            await connection.close()

            #expect(result.standardOutputText == "SERVICE_TOKEN_OK\n")

            let headers = carrier.observedUpgradeHeaders()
            #expect(headers.last?.first(name: "Cf-Access-Client-Id") == service.id)
            #expect(headers.last?.first(name: "Cf-Access-Client-Secret") == service.secret)
            #expect(headers.last?.first(name: "User-Agent") == "SuperTerminal/test")
        }
    }

    @Test("The bastion destination is sent as Cf-Access-Jump-Destination")
    func jumpDestinationHeaderIsSent() async throws {
        try await withHarness { ssh, carrier, group in
            let key = try OpenSSHPrivateKeyParser.parse(pem: ssh.fixtures.clientPrivateKeyPEM)
            let identity = KnownHostIdentity(
                host: "127.0.0.1",
                port: carrier.port,
                jumpDestination: "internal.example.com:22"
            )
            let connection = try await SSHConnection.connect(
                transport: makeTransport(
                    port: carrier.port,
                    credential: .none,
                    jumpDestination: "internal.example.com:22"
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
            await connection.close()

            let headers = carrier.observedUpgradeHeaders()
            #expect(headers.last?.first(name: "Cf-Access-Jump-Destination") == "internal.example.com:22")
        }
    }

    @Test(
        "Each edge failure is reported as its own actionable error",
        arguments: [
            (WebSocketCarrierTestServer.Behaviour.redirectToAccessLogin, STErrorCategory.access),
            (.forbidden, .access),
            (.originUnreachable, .tunnel),
            (.tunnelOffline, .tunnel),
        ]
    )
    func edgeFailuresAreClassified(
        behaviour: WebSocketCarrierTestServer.Behaviour,
        expected: STErrorCategory
    ) async throws {
        try await withHarness(behaviour: behaviour) { _, carrier, group in
            var caught: STError?
            do {
                _ = try await makeTransport(port: carrier.port, credential: .none)
                    .connect(on: group.next())
            } catch let error as STError {
                caught = error
            }
            #expect(caught?.category == expected)
            // Every user-facing failure must say what to do next.
            #expect(caught?.recoverySuggestion?.isEmpty == false)
        }
    }

    @Test("A plaintext carrier refuses any host that is not loopback")
    func plaintextCarrierRefusesRemoteHosts() async throws {
        let group = NIOTSEventLoopGroup.singleton

        let transport = CloudflareCarrierTransport(
            configuration: .init(
                host: "ssh.example.com",
                port: 443,
                userAgent: "SuperTerminal/test",
                security: .plaintextLoopbackOnly
            ),
            credential: .none
        )
        var caught: STError?
        do {
            _ = try await transport.connect(on: group.next())
        } catch let error as STError {
            caught = error
        }
        #expect(caught?.category == .configuration)
    }
}
