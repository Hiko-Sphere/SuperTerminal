import Foundation
import STCore
import STSSH
import STTerminal
import Testing

@testable import ApexTerminal

/// Pictures over a real connection, and the pixel size the far side needs to draw one (D-065).
///
/// The decoders are proved against other implementations in the package's own tests. What is
/// proved here is the part only a real session can show: a sixel written by a program on the
/// server arrives, becomes a picture in the grid, and the server was told how big a cell is —
/// which is the number `img2sixel` and its like divide by, and which this app sent as zero
/// until now.
@Suite(
    "Pictures, in a session",
    .enabled(if: AppIntegrationEnvironment.current != nil, "run scripts/app-integration-e2e.sh"),
    .serialized
)
@MainActor
struct GraphicsSessionTests {
    private func makeSession() throws -> (TerminalSession, SessionManager) {
        guard let environment = AppIntegrationEnvironment.current else { throw AppIntegrationEnvironment.Missing() }
        let keyID = UUID()
        let vault = CredentialVault()
        try vault.storePrivateKey(environment.privateKeyPEM, id: keyID, requireBiometrics: false)
        let host = Host(
            name: "Integration", hostname: environment.host, port: environment.port,
            username: environment.username, transport: .directTCP, credentials: [.privateKey(id: keyID)]
        )
        let settings = AppSettings(defaults: UserDefaults(suiteName: "graphics-\(UUID())")!)
        let manager = SessionManager(
            vault: vault, knownHosts: InMemoryKnownHostsStore(), settings: settings,
            diagnostics: DiagnosticsCentre()
        )
        return (manager.open(host), manager)
    }

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

    @Test("A picture a program draws arrives as a picture", .timeLimit(.minutes(2)))
    func aSixelFromTheServerBecomesAPicture() async throws {
        let (session, manager) = try makeSession()
        defer { manager.closeAll() }
        await connect(session)
        #expect(await wait { session.screen.visibleText.isEmpty == false }, "the shell should start")
        await session.resize(columns: 80, rows: 24, pixelWidth: 640, pixelHeight: 408)

        // Twelve pixels by six, one colour, written by the shell. `printf` assembles it so
        // the echo of the command cannot be mistaken for the sequence itself.
        await session.send(#"printf '\033P0;0;0q"1;1;12;6#0;2;100;0;0#0!12~\033\\'"# + "\n")

        #expect(await wait { session.screen.images.count > 0 }, "the sixel should decode into the screen's store")
        let drawn = session.screen.lines.contains { !$0.imageSlices.isEmpty }
            || session.screen.scrollback.contains { !$0.imageSlices.isEmpty }
        #expect(drawn, "and it should occupy cells in the grid")
    }

    @Test("The server is told how big a cell is", .timeLimit(.minutes(2)))
    func theServerLearnsThePixelSize() async throws {
        let (session, manager) = try makeSession()
        defer { manager.closeAll() }
        await connect(session)
        #expect(await wait { session.screen.visibleText.isEmpty == false })

        // A grid of 80×24 cells that is 640×408 pixels: eight-pixel columns, seventeen-pixel
        // rows. `ws_xpixel` and `ws_ypixel` are the only way a program can know that, and
        // they are what this app sent as zero before D-065.
        await session.resize(columns: 80, rows: 24, pixelWidth: 640, pixelHeight: 408)
        #expect(session.size.pixelWidth == 640)
        #expect(session.size.pixelHeight == 408)

        await session.send(
            "python3 -c \"import fcntl,termios,struct,sys;"
                + "r,c,x,y=struct.unpack('hhhh',fcntl.ioctl(sys.stdout,termios.TIOCGWINSZ,b'\\0'*8));"
                + "print('WINSZ_%d_%d_%d_%d'%(r,c,x,y))\"\n"
        )
        _ = await wait { session.screen.visibleText.contains("WINSZ_24_80_") }
        let text = session.screen.visibleText
        // The echoed command contains the format string, not the answer: the answer is the
        // line with the numbers filled in.
        #expect(text.contains("WINSZ_24_80_640_408"),
                "the server should see the pixel size. Screen:\n\(text.suffix(500))")
    }
}
