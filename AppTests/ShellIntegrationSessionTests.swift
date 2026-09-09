import Foundation
import STCore
import STSSH
import STTerminal
import Testing
import UIKit

@testable import ApexTerminal

/// What a real shell's escape sequences do to a real session (D-062).
///
/// The emulator's tests prove the sequences are understood. These prove the app acts on
/// them the way it promises: the clipboard is not written unless the person allowed it, the
/// working directory follows the shell, and OSC 133 is noticed.
@Suite(
    "Shell integration, in a session",
    .enabled(if: AppIntegrationEnvironment.current != nil, "run scripts/app-integration-e2e.sh"),
    .serialized
)
@MainActor
struct ShellIntegrationSessionTests {
    private func makeSession(clipboardAllowed: Bool) throws -> (TerminalSession, SessionManager, AppSettings) {
        guard let environment = AppIntegrationEnvironment.current else { throw AppIntegrationEnvironment.Missing() }
        let keyID = UUID()
        let vault = CredentialVault()
        try vault.storePrivateKey(environment.privateKeyPEM, id: keyID, requireBiometrics: false)
        let host = Host(
            name: "Integration", hostname: environment.host, port: environment.port,
            username: environment.username, transport: .directTCP, credentials: [.privateKey(id: keyID)]
        )
        let settings = AppSettings(defaults: UserDefaults(suiteName: "osc-\(UUID())")!)
        settings.remoteClipboardWrites = clipboardAllowed
        let manager = SessionManager(
            vault: vault, knownHosts: InMemoryKnownHostsStore(), settings: settings,
            diagnostics: DiagnosticsCentre()
        )
        return (manager.open(host), manager, settings)
    }

    /// Waits for the session `SessionManager.open` already started, approving the server's
    /// key the way a person would on a first connection.
    ///
    /// Not `session.connect()`: opening a session starts it connecting, and calling again
    /// starts a second attempt over the top of the first — measured, as a session that
    /// reported "Not connected" while the harness's `sshd` was plainly there.
    ///
    /// The harness's key has never been seen by this device, and the app stops for it,
    /// which is the behaviour the User Notice promises. Answering it here exercises that
    /// path rather than skipping it.
    private func connect(_ session: TerminalSession) async {
        _ = await wait {
            if case .awaitingUser = session.state { return true }
            if case .connected = session.state { return true }
            if case .failed = session.state { return true }
            return false
        }
        if case .awaitingUser = session.state { session.resolvePrompt(.approve) }
        _ = await wait {
            if case .connected = session.state { return true }
            if case .failed = session.state { return true }
            return false
        }
    }

    private func wait(timeout: Duration = .seconds(30), until condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    @Test("The shell's working directory reaches the session", .timeLimit(.minutes(2)))
    func reportsWorkingDirectory() async throws {
        let (session, manager, _) = try makeSession(clipboardAllowed: false)
        defer { manager.closeAll() }
        await connect(session)
        #expect(await wait { session.screen.visibleText.isEmpty == false }, "the shell should start")

        // Sent as a shell would after a `cd`. `printf` builds it so the echo of the command
        // cannot be mistaken for the sequence itself.
        await session.send("printf '\\033]7;file://localhost/tmp\\007'\n")
        _ = await wait { session.workingDirectory == "/tmp" }
        #expect(session.workingDirectory == "/tmp",
                "OSC 7 should reach the session; got '\(session.workingDirectory)'. Screen:\n\(session.screen.visibleText.suffix(400))")
    }

    @Test("A program cannot write the clipboard unless it is allowed", .timeLimit(.minutes(2)))
    func clipboardIsRefusedByDefault() async throws {
        let marker = "REFUSED-\(UUID().uuidString.prefix(8))"
        UIPasteboard.general.string = "untouched"

        let (session, manager, _) = try makeSession(clipboardAllowed: false)
        defer { manager.closeAll() }
        await connect(session)
        #expect(await wait { session.screen.visibleText.isEmpty == false })

        let encoded = Data(marker.utf8).base64EncodedString()
        await session.send("printf '\\033]52;c;\(encoded)\\007'\n")
        // The refusal is said once, which is also how this test knows the request arrived
        // rather than never having been sent.
        #expect(await wait { session.screen.visibleText.contains("clipboard") },
                "the session should say a program tried")
        #expect(UIPasteboard.general.string == "untouched", "and the clipboard must be untouched")
    }

    @Test("With permission, a program's copy reaches the clipboard", .timeLimit(.minutes(2)))
    func clipboardIsWrittenWhenAllowed() async throws {
        let marker = "ALLOWED-\(UUID().uuidString.prefix(8))"
        UIPasteboard.general.string = "untouched"

        let (session, manager, _) = try makeSession(clipboardAllowed: true)
        defer { manager.closeAll() }
        await connect(session)
        #expect(await wait { session.screen.visibleText.isEmpty == false })

        let encoded = Data(marker.utf8).base64EncodedString()
        await session.send("printf '\\033]52;c;\(encoded)\\007'\n")
        #expect(await wait { UIPasteboard.general.string == marker },
                "the copy should reach the clipboard; it holds \(UIPasteboard.general.string ?? "nothing")")
    }

    @Test("A shell that speaks OSC 133 is noticed, with the exit status", .timeLimit(.minutes(2)))
    func noticesShellIntegration() async throws {
        let (session, manager, _) = try makeSession(clipboardAllowed: false)
        defer { manager.closeAll() }
        await connect(session)
        #expect(await wait { session.screen.visibleText.isEmpty == false })

        #expect(!session.shellIntegration, "nothing has said so yet")
        await session.send("printf '\\033]133;D;3\\007'\n")
        #expect(await wait { session.shellIntegration })
        #expect(session.lastExitCode == 3, "the status the shell reported, not one inferred")
    }
}
