import Foundation
import NIOTransportServices
import Observation
import STCore
import STSSH

/// The remote screens that are open, app-wide (D-022). Kept apart from the terminal
/// sessions: a screen is not a terminal, and the parts of the app that step through
/// sessions — ⌘1…9, the palette, "next session" — should not land on one.
@Observable
@MainActor
final class VNCSessionManager {
    private(set) var sessions: [VNCSession] = []

    private let group = NIOTSEventLoopGroup(loopCount: 1)
    private let vault: CredentialVault
    private let knownHosts: any KnownHostsStore
    private let diagnostics: DiagnosticsCentre
    private let haptics: Haptics?
    /// The same two providers every other kind of session gets (D-046): a screen behind a
    /// certificate-authenticated host must connect the same way its terminal does.
    var certificateForKey: @Sendable (UUID) -> SSHCertificate? = { _ in nil }
    var certificateAuthorities: @Sendable () -> [SSHCertificateAuthority] = { [] }
    var hostByID: @Sendable (UUID) -> Host? = { _ in nil }

    init(
        vault: CredentialVault,
        knownHosts: any KnownHostsStore,
        diagnostics: DiagnosticsCentre,
        haptics: Haptics? = nil
    ) {
        self.vault = vault
        self.knownHosts = knownHosts
        self.diagnostics = diagnostics
        self.haptics = haptics
    }

    /// Opens `screen`, through `sshHost` when its route names one. Connecting starts at
    /// once; the caller resolves the host so a route naming a deleted connection arrives
    /// as `nil` and is reported rather than silently changed.
    func open(_ screen: ScreenConnection, through sshHost: Host?) -> VNCSession {
        let session = VNCSession(
            screen: screen,
            sshHost: sshHost,
            group: group,
            vault: vault,
            knownHosts: knownHosts,
            log: diagnostics.logger,
            haptics: haptics,
            certificateForKey: certificateForKey,
            certificateAuthorities: certificateAuthorities(),
            hostByID: hostByID
        )
        sessions.append(session)
        Task { await session.connect() }
        return session
    }

    func close(_ session: VNCSession) {
        sessions.removeAll { $0.id == session.id }
        Task { await session.disconnect() }
    }

    func closeAll() {
        let open = sessions
        sessions = []
        for session in open { Task { await session.disconnect() } }
    }

    func session(withID id: VNCSession.ID?) -> VNCSession? {
        guard let id else { return nil }
        return sessions.first { $0.id == id }
    }

    func sessions(for screen: ScreenConnection) -> [VNCSession] {
        sessions.filter { $0.screen.id == screen.id }
    }
}
