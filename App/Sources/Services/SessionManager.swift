import Foundation
import NIOTransportServices
import Observation
import STCore
import STSSH

/// Owns every live terminal session.
///
/// Sessions outlive the views that show them: switching tabs on iPhone or moving a
/// window on iPad must not drop a connection, so ownership sits here rather than in a
/// view model tied to a screen.
@Observable
@MainActor
final class SessionManager {
    private(set) var sessions: [TerminalSession] = []
    var selectedSessionID: TerminalSession.ID?

    private let group: NIOTSEventLoopGroup
    private let vault: CredentialVault
    private let knownHosts: any KnownHostsStore
    private let settings: AppSettings
    private let diagnostics: DiagnosticsCentre

    init(
        vault: CredentialVault,
        knownHosts: any KnownHostsStore,
        settings: AppSettings,
        diagnostics: DiagnosticsCentre
    ) {
        // One loop per core, shared by every session: each connection is mostly idle
        // waiting for a person to type, so a loop per session would be threads doing
        // nothing.
        group = NIOTSEventLoopGroup()
        self.vault = vault
        self.knownHosts = knownHosts
        self.settings = settings
        self.diagnostics = diagnostics
    }

    var selectedSession: TerminalSession? {
        guard let selectedSessionID else { return nil }
        return sessions.first { $0.id == selectedSessionID }
    }

    @discardableResult
    func open(_ host: Host) -> TerminalSession {
        let session = TerminalSession(
            host: host,
            group: group,
            vault: vault,
            knownHosts: knownHosts,
            settings: settings,
            log: diagnostics.logger
        )
        sessions.append(session)
        selectedSessionID = session.id
        Task { await session.connect() }
        return session
    }

    func close(_ session: TerminalSession) {
        Task { await session.disconnect() }
        sessions.removeAll { $0.id == session.id }
        if selectedSessionID == session.id {
            selectedSessionID = sessions.last?.id
        }
    }

    func closeAll() {
        for session in sessions {
            Task { await session.disconnect() }
        }
        sessions.removeAll()
        selectedSessionID = nil
    }

    /// Sessions for a given host, so the host list can show what is already open.
    func sessions(for host: Host) -> [TerminalSession] {
        sessions.filter { $0.host.id == host.id }
    }
}
