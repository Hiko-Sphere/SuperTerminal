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

    /// Which window is currently displaying each session.
    ///
    /// A terminal's size is a property of the connection, not of a view: the remote
    /// program is told how many columns and rows it has. Two windows showing the same
    /// session would each report their own geometry and resize the far end against each
    /// other, so exactly one window displays a session at a time and only that window
    /// reports its size.
    private(set) var displayOwners: [TerminalSession.ID: UUID] = [:]

    private let group: NIOTSEventLoopGroup
    private let vault: CredentialVault
    private let knownHosts: any KnownHostsStore
    private let settings: AppSettings
    private let diagnostics: DiagnosticsCentre
    /// Optional so a test can run without a live path monitor, or drive one by hand.
    private let reachability: NetworkReachability?
    private let restoration: SessionRestorationStore?

    init(
        vault: CredentialVault,
        knownHosts: any KnownHostsStore,
        settings: AppSettings,
        diagnostics: DiagnosticsCentre,
        reachability: NetworkReachability? = nil,
        restoration: SessionRestorationStore? = nil
    ) {
        // One loop per core, shared by every session: each connection is mostly idle
        // waiting for a person to type, so a loop per session would be threads doing
        // nothing.
        group = NIOTSEventLoopGroup()
        self.vault = vault
        self.knownHosts = knownHosts
        self.settings = settings
        self.diagnostics = diagnostics
        self.reachability = reachability
        self.restoration = restoration
    }

    /// Writes down what is open, so a relaunch can offer to reopen it.
    private func rememberOpenSessions() {
        restoration?.record(hosts: sessions.map { (id: $0.host.id, name: $0.host.name) })
    }

    func session(withID id: TerminalSession.ID?) -> TerminalSession? {
        guard let id else { return nil }
        return sessions.first { $0.id == id }
    }

    // MARK: - Display ownership

    func owner(ofSessionWithID id: TerminalSession.ID) -> UUID? { displayOwners[id] }

    /// Gives a window the right to display a session, taking it from whichever window
    /// held it. The previous holder notices and stops showing it.
    func claimDisplay(ofSessionWithID id: TerminalSession.ID, by scene: UUID) {
        displayOwners[id] = scene
    }

    /// The first session no window is displaying.
    ///
    /// What a newly opened window should show: picking the first session outright would
    /// take it away from the window that is already showing it, which is a strange thing
    /// for opening a *new* window to do.
    func firstUnclaimedSession() -> TerminalSession? {
        sessions.first { displayOwners[$0.id] == nil }
    }

    /// Gives up a claim, but only if this window still holds it.
    ///
    /// Windows appear and disappear in an order SwiftUI decides: a new window can claim
    /// a session before the old one has finished going away. Checking the holder means a
    /// departing window cannot revoke the claim of the window that just took over.
    func releaseDisplay(ofSessionWithID id: TerminalSession.ID, by scene: UUID) {
        if displayOwners[id] == scene { displayOwners[id] = nil }
    }

    @discardableResult
    func open(_ host: Host) -> TerminalSession {
        let session = TerminalSession(
            host: host,
            group: group,
            vault: vault,
            knownHosts: knownHosts,
            settings: settings,
            log: diagnostics.logger,
            reachability: reachability
        )
        sessions.append(session)
        rememberOpenSessions()
        Task { await session.connect() }
        return session
    }

    func close(_ session: TerminalSession) {
        Task { await session.disconnect() }
        sessions.removeAll { $0.id == session.id }
        displayOwners[session.id] = nil
        rememberOpenSessions()
    }

    func closeAll() {
        for session in sessions {
            Task { await session.disconnect() }
        }
        sessions.removeAll()
        displayOwners.removeAll()
        rememberOpenSessions()
    }

    /// Sessions for a given host, so the host list can show what is already open.
    func sessions(for host: Host) -> [TerminalSession] {
        sessions.filter { $0.host.id == host.id }
    }
}
