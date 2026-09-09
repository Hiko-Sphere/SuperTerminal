import CryptoKit
import Foundation
import STCore
import STSSH
import Testing

@testable import ApexTerminal

/// Keyboard-interactive as the app performs it (D-051).
///
/// The server is stock OpenSSH in a container, accepting nothing but
/// `keyboard-interactive` and asking two questions through PAM. What is under test here is
/// not the protocol — the package suite covers that against the same server — but the
/// app's own path: the questions reach `TerminalSession` as a prompt, the answers go back
/// through `PromptCoordinator`, and the session ends up connected.
@Suite(
    "Keyboard-interactive through the app",
    .enabled(if: KeyboardInteractiveEnvironment.current != nil, "run scripts/app-integration-e2e.sh with Docker running"),
    .serialized
)
@MainActor
struct KeyboardInteractiveAuthTests {
    @Test("The server's questions reach the UI and the answers get in", .timeLimit(.minutes(3)))
    func challengeReachesTheSessionAndAuthenticates() async throws {
        let environment = try #require(KeyboardInteractiveEnvironment.current)

        // No stored credential at all: the only way in is to answer what the server asks.
        let host = Host(
            name: "Two factor",
            hostname: "127.0.0.1",
            port: environment.port,
            username: environment.username,
            transport: .directTCP,
            credentials: []
        )
        let manager = SessionManager(
            vault: CredentialVault(),
            knownHosts: InMemoryKnownHostsStore(),
            settings: AppSettings(defaults: UserDefaults(suiteName: "kbdi-\(UUID())")!),
            diagnostics: DiagnosticsCentre()
        )
        defer { manager.closeAll() }

        let session = manager.open(host)
        var rounds: [SSHKeyboardInteractiveChallenge] = []

        // Answer whatever comes, as a person would: the host key first, then each round of
        // questions, until the session settles.
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            if case .connected = session.state { break }
            if case .failed = session.state { break }
            if case let .awaitingUser(prompt) = session.state {
                switch prompt {
                case .unknownHostKey:
                    session.resolvePrompt(.approve)
                case let .keyboardInteractive(_, challenge):
                    rounds.append(challenge)
                    session.resolvePrompt(.answers(challenge.prompts.map { answer(to: $0, environment) }))
                default:
                    Issue.record("unexpected prompt \(prompt)")
                    session.resolvePrompt(.reject)
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        #expect(session.isConnected, "state was \(session.state)")

        // The rounds with prompts are the ones a person sees. The empty final round is
        // answered without a sheet, so it does not appear here.
        #expect(rounds.count == 2, "saw \(rounds.map(\.prompts))")
        #expect(rounds.first?.prompts.first?.prompt.lowercased().contains("password") == true)
        #expect(rounds.last?.prompts.first?.prompt.lowercased().contains("verification code") == true)
        // Every field must be a secure one.
        #expect(rounds.flatMap(\.prompts).allSatisfy { !$0.echo })
    }

    @Test("Dismissing the sheet fails the session with a reason a person can act on", .timeLimit(.minutes(3)))
    func dismissingTheSheetFailsCleanly() async throws {
        let environment = try #require(KeyboardInteractiveEnvironment.current)

        let host = Host(
            name: "Two factor",
            hostname: "127.0.0.1",
            port: environment.port,
            username: environment.username,
            transport: .directTCP,
            credentials: []
        )
        let manager = SessionManager(
            vault: CredentialVault(),
            knownHosts: InMemoryKnownHostsStore(),
            settings: AppSettings(defaults: UserDefaults(suiteName: "kbdi-\(UUID())")!),
            diagnostics: DiagnosticsCentre()
        )
        defer { manager.closeAll() }

        let session = manager.open(host)
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            if case .connected = session.state { break }
            if case .failed = session.state { break }
            if case let .awaitingUser(prompt) = session.state {
                switch prompt {
                case .unknownHostKey: session.resolvePrompt(.approve)
                case .keyboardInteractive: session.resolvePrompt(.reject)
                default: session.resolvePrompt(.reject)
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        #expect(!session.isConnected)
        guard case let .failed(error) = session.state else {
            Issue.record("expected a failure, state was \(session.state)")
            return
        }
        // Not a bare code: whoever dismissed the sheet has to be told what to do next.
        #expect(!error.message.isEmpty)
    }

    private func answer(
        to prompt: SSHKeyboardInteractiveChallenge.Prompt,
        _ environment: KeyboardInteractiveEnvironment
    ) -> String {
        prompt.prompt.lowercased().contains("verification code")
            ? environment.currentCode()
            : environment.password
    }
}

/// What `scripts/app-integration-e2e.sh` publishes about the container, when Docker was
/// available to start one.
struct KeyboardInteractiveEnvironment {
    let port: Int
    let username: String
    let password: String
    let secret: String

    static var current: KeyboardInteractiveEnvironment? {
        let environment = ProcessInfo.processInfo.environment
        guard let portText = environment["ST_APP_TEST_KBDI_PORT"], let port = Int(portText),
            let username = environment["ST_APP_TEST_KBDI_USER"], !username.isEmpty,
            let password = environment["ST_APP_TEST_KBDI_PASSWORD"], !password.isEmpty,
            let secret = environment["ST_APP_TEST_KBDI_SECRET"], !secret.isEmpty
        else { return nil }
        return KeyboardInteractiveEnvironment(port: port, username: username, password: password, secret: secret)
    }

    /// RFC 6238 over CryptoKit's HMAC-SHA1 — a code, not a primitive.
    ///
    /// The same few lines exist in `STTestSupport.KeyboardInteractiveTestServer` for the
    /// package tests; the app target does not link that module, and sharing it would mean
    /// putting test-only code into a shipping one.
    func currentCode(at date: Date = Date()) -> String {
        var counter = UInt64(date.timeIntervalSince1970 / 30).bigEndian
        let key = SymmetricKey(data: Self.base32Decode(secret))
        let digest = withUnsafeBytes(of: &counter) { bytes in
            Array(HMAC<Insecure.SHA1>.authenticationCode(for: Data(bytes), using: key))
        }
        let offset = Int(digest[digest.count - 1] & 0x0F)
        let truncated =
            (UInt32(digest[offset] & 0x7F) << 24)
            | (UInt32(digest[offset + 1]) << 16)
            | (UInt32(digest[offset + 2]) << 8)
            | UInt32(digest[offset + 3])
        return String(format: "%06u", truncated % 1_000_000)
    }

    private static func base32Decode(_ text: String) -> Data {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0
        var value = 0
        var output = Data()
        for character in text.uppercased() where character != "=" {
            guard let index = alphabet.firstIndex(of: character) else { continue }
            value = (value << 5) | index
            bits += 5
            if bits >= 8 {
                output.append(UInt8((value >> (bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        return output
    }
}
