import Foundation
import NIOSSH
import NIOTransportServices
import STCore
@testable import STSSH
import STTestSupport
import Testing

/// RFC 4256 keyboard-interactive, against a real OpenSSH server that accepts nothing else
/// (D-051).
///
/// The server is stock OpenSSH in a container, configured with `AuthenticationMethods
/// keyboard-interactive` and a PAM stack of `pam_unix` followed by
/// `pam_google_authenticator`. So a login here needs two questions answered in order —
/// a password and a one-time code — and there is no other method the client could have
/// quietly used instead.
///
/// This machine's own `sshd` cannot stand in for it: macOS builds OpenSSH without PAM, and
/// its keyboard-interactive path then asks for a real account's login password.
@Suite(
    "Keyboard-interactive against real OpenSSH",
    .enabled(if: KeyboardInteractiveTestServer.isAvailable, "needs Docker running"),
    .serialized
)
struct KeyboardInteractiveTests {
    /// Answers the way a person would, using what the fixture knows.
    private func answering(
        _ server: KeyboardInteractiveTestServer,
        record: (@Sendable (SSHKeyboardInteractiveChallenge) -> Void)? = nil
    ) -> SSHCredential {
        let fixtures = server.fixtures
        return .keyboardInteractive { challenge in
            record?(challenge)
            return challenge.prompts.map { prompt in
                // The prompts are the server's own words, so this matches on what they
                // actually say rather than assuming an order.
                if prompt.prompt.lowercased().contains("verification code") {
                    return KeyboardInteractiveTestServer.timeBasedCode(secret: fixtures.totpSecret)
                }
                return fixtures.password
            }
        }
    }

    @Test("Two prompts are answered in one exchange and the login succeeds", .timeLimit(.minutes(3)))
    func twoPromptExchangeAuthenticates() async throws {
        let server = try KeyboardInteractiveTestServer()
        defer { server.shutDown() }

        let seen = ChallengeRecorder()
        let connection = try await connect(
            to: server,
            credentials: [answering(server, record: { seen.record($0) })]
        )
        let result = try await connection.execute(command: "printf KBDI_OK")
        #expect(result.standardOutputText == "KBDI_OK")
        await connection.close()

        // The point of the test is the *rounds*. What this server actually sends, measured:
        //
        //   1. one prompt, "Password: "
        //   2. one prompt, "Verification code: "
        //   3. no prompts at all
        //
        // The third is not a quirk — RFC 4256 § 3.3 defines a round with zero prompts, and
        // requires the client to answer it with zero responses and keep waiting. It is the
        // case an implementation that assumed "a round means a question" gets wrong, by
        // hanging or by sending an answer nobody asked for, so it is asserted rather than
        // tolerated.
        let challenges = seen.challenges
        #expect(challenges.count == 3, "saw \(challenges.map(\.prompts))")

        let first = try #require(challenges.first)
        #expect(first.prompts.count == 1)
        #expect(first.prompts.first?.prompt.lowercased().contains("password") == true, "\(first.prompts)")

        let second = try #require(challenges.dropFirst().first)
        #expect(second.prompts.count == 1)
        #expect(
            second.prompts.first?.prompt.lowercased().contains("verification code") == true,
            "\(second.prompts)"
        )

        #expect(challenges.last?.prompts.isEmpty == true, "the final round should carry no prompts")

        // Neither secret may be echoed. A client that ignored this would put a password
        // and a one-time code on screen.
        #expect(challenges.flatMap(\.prompts).allSatisfy { !$0.echo })

        // sshd's own log names the method it accepted.
        let log = server.log()
        #expect(log.contains("Accepted keyboard-interactive/pam"), "sshd said:\n\(log)")
    }

    @Test("A wrong answer to either prompt is refused", .timeLimit(.minutes(3)))
    func wrongAnswersAreRefused() async throws {
        let server = try KeyboardInteractiveTestServer()
        defer { server.shutDown() }

        // The right password and a code that is not the current one. Without this the test
        // above could pass because the server accepted anything at all.
        let fixtures = server.fixtures
        let credential = SSHCredential.keyboardInteractive { challenge in
            challenge.prompts.map { prompt in
                prompt.prompt.lowercased().contains("verification code") ? "000000" : fixtures.password
            }
        }

        var caught: Error?
        do {
            let connection = try await connect(to: server, credentials: [credential])
            await connection.close()
        } catch {
            caught = error
        }
        #expect(caught != nil, "a wrong one-time code must not get in")
    }

    @Test("Cancelling a prompt ends the attempt instead of sending blanks", .timeLimit(.minutes(3)))
    func cancellationEndsTheAttempt() async throws {
        let server = try KeyboardInteractiveTestServer()
        defer { server.shutDown() }

        let asked = ChallengeRecorder()
        let credential = SSHCredential.keyboardInteractive { challenge in
            asked.record(challenge)
            return nil  // the person dismissed the sheet
        }

        var caught: Error?
        do {
            let connection = try await connect(to: server, credentials: [credential])
            await connection.close()
        } catch {
            caught = error
        }
        #expect(caught != nil, "a cancelled prompt must not connect")
        #expect(asked.challenges.count == 1, "the responder should have been asked once")

        // And the server must not have counted a failed password: nothing was sent. Its
        // log would say `Failed keyboard-interactive/pam` if blanks had gone out.
        let log = server.log()
        #expect(!log.contains("Failed keyboard-interactive"), "blank answers were sent:\n\(log)")
    }

    @Test("The credential chain skips keyboard-interactive when the server will not take it")
    func chainRespectsTheServersMethods() {
        // Nothing to do with the container: this is the chain's own rule, and it is what
        // stops an offer being spent against `MaxAuthTries` for nothing.
        let chain = SSHCredentialChain(
            username: "u",
            credentials: [.keyboardInteractive { _ in [] }]
        )
        let loop = NIOTSEventLoopGroup.singleton.next()
        let promise = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        chain.nextAuthenticationType(availableMethods: [.password], nextChallengePromise: promise)

        var failed = false
        do {
            _ = try promise.futureResult.wait()
        } catch {
            failed = true
        }
        #expect(failed, "with only password on offer there is nothing left to try")
    }

    private func connect(
        to server: KeyboardInteractiveTestServer,
        credentials: [SSHCredential]
    ) async throws -> SSHConnection {
        let identity = KnownHostIdentity(host: server.fixtures.host, port: server.fixtures.port)
        return try await SSHConnection.connect(
            transport: DirectTCPTransport(
                endpoint: TransportEndpoint(host: server.fixtures.host, port: server.fixtures.port)
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
            eventLoop: NIOTSEventLoopGroup.singleton.next()
        )
    }
}

/// Collects what the server asked, across rounds, from whichever thread answers.
private final class ChallengeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SSHKeyboardInteractiveChallenge] = []

    func record(_ challenge: SSHKeyboardInteractiveChallenge) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(challenge)
    }

    var challenges: [SSHKeyboardInteractiveChallenge] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
