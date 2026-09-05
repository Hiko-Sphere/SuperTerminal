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

    /// Opens a screen to `host`, which must have screen sharing configured; connecting
    /// starts at once.
    func open(_ host: Host, settings: Host.VNCSettings) -> VNCSession {
        let session = VNCSession(
            host: host,
            settings: settings,
            group: group,
            vault: vault,
            knownHosts: knownHosts,
            log: diagnostics.logger,
            haptics: haptics
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

    func sessions(for host: Host) -> [VNCSession] {
        sessions.filter { $0.host.id == host.id }
    }
}
