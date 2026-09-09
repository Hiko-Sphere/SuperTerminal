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
    /// File browsers, kept the same way shells are, so more than one folder can be open
    /// and each can be put in a pane of its own (D-071).
    private(set) var fileSessions: [SFTPSession] = []
    /// A connection succeeded; the known-hosts file may have a new entry to sync.
    var didConnect: (() -> Void)?
    /// A server reported its platform; the container records it against the host.
    var didDetectPlatform: ((Host.ID, HostPlatform) -> Void)?

    /// Which window is currently displaying each session.
    ///
    /// A terminal's size is a property of the connection, not of a view: the remote
    /// program is told how many columns and rows it has. Two windows showing the same
    /// session would each report their own geometry and resize the far end against each
    /// other, so exactly one window displays a session at a time and only that window
    /// reports its size.
    private(set) var displayOwners: [TerminalSession.ID: UUID] = [:]

    private let group: NIOTSEventLoopGroup
    /// One shared transport per identity, for every kind of session (D-054). Owned here
    /// because this is what outlives individual sessions.
    let pool = SSHConnectionPool()
    private let vault: CredentialVault
    private let knownHosts: any KnownHostsStore
    private let settings: AppSettings
    private let diagnostics: DiagnosticsCentre
    /// Optional so a test can run without a live path monitor, or drive one by hand.
    private let reachability: NetworkReachability?
    private let restoration: SessionRestorationStore?
    private let haptics: Haptics?
    /// The saved record for a key — where its private half is kept (D-049) and the
    /// certificate issued for it (D-046) — and the authorities trusted to vouch for
    /// servers. Set by the container from the host store, so a session does not have to
    /// know where either lives.
    var keyRecord: @Sendable (UUID) -> StoredKey? = { _ in nil }
    var certificateAuthorities: @Sendable () -> [SSHCertificateAuthority] = { [] }
    /// Resolves a saved connection for a jump chain (D-047).
    var hostByID: @Sendable (UUID) -> Host? = { _ in nil }

    init(
        vault: CredentialVault,
        knownHosts: any KnownHostsStore,
        settings: AppSettings,
        diagnostics: DiagnosticsCentre,
        reachability: NetworkReachability? = nil,
        restoration: SessionRestorationStore? = nil,
        haptics: Haptics? = nil
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
        self.haptics = haptics
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

    /// A file-browsing session for one connection (D-042). Built here because this is
    /// where the event-loop group, the vault and the known-hosts store already live.
    ///
    /// The prompt coordinator is its own: a browsing session is not a terminal session,
    /// and sharing one would let a password sheet raised by a file transfer land on the
    /// wrong screen (D-043).
    func makeFileSession(for host: Host) -> SFTPSession {
        let prompts = PromptCoordinator()
        return SFTPSession(
            hostID: host.id,
            hostName: host.name,
            connector: HostConnector(
                host: host, group: group, vault: vault, knownHosts: knownHosts,
                log: diagnostics.logger, prompts: prompts,
                keyRecord: keyRecord,
                certificateAuthorities: certificateAuthorities(),
                hostByID: hostByID,
                pool: pool
            ),
            prompts: prompts,
            log: diagnostics.logger
        )
    }

    /// The connector and prompt coordinator for a tmux session (D-059).
    ///
    /// Built here for the same reason the file browser's is: this is where the event-loop
    /// group, the vault, the known-hosts store and the connection pool already are. Its own
    /// prompt coordinator, so a host-key question raised while attaching does not land on
    /// a terminal's screen.
    func makeTmuxConnector(for host: Host) -> (connector: HostConnector, prompts: PromptCoordinator) {
        let prompts = PromptCoordinator()
        return (
            HostConnector(
                host: host, group: group, vault: vault, knownHosts: knownHosts,
                log: diagnostics.logger, prompts: prompts,
                keyRecord: keyRecord,
                certificateAuthorities: certificateAuthorities(),
                hostByID: hostByID,
                pool: pool
            ),
            prompts
        )
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
            reachability: reachability,
            haptics: haptics,
            keyRecord: keyRecord,
            certificateAuthorities: certificateAuthorities(),
            hostByID: hostByID,
            pool: pool
        )
        session.onConnected = { [weak self] in self?.didConnect?() }
        session.onPlatformDetected = { [weak self] platform in self?.didDetectPlatform?(host.id, platform) }
        sessions.append(session)
        rememberOpenSessions()
        Task { await session.connect() }
        return session
    }

    /// Opens a file browser and keeps it, so several can be on screen at once (D-071).
    ///
    /// A new one every time, like `open(_:)` for a shell: two folders on the same server is
    /// the ordinary reason to want two browsers, and reusing one would make the second
    /// request move the first.
    @discardableResult
    func openFiles(_ host: Host) -> SFTPSession {
        let session = makeFileSession(for: host)
        fileSessions.append(session)
        // Not connected here: the browser connects from its own `.task` when it appears, and
        // starting a second attempt over the top of the first is what made a terminal report
        // "Not connected" against a server that was plainly there (D-062).
        return session
    }

    func closeFiles(_ session: SFTPSession) {
        Task { await session.disconnect() }
        fileSessions.removeAll { $0.id == session.id }
    }

    func fileSession(id: UUID) -> SFTPSession? {
        fileSessions.first { $0.id == id }
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

    /// The session a number key selects. One-based, because ⌘1 is the first.
    ///
    /// Out of range returns `nil` rather than clamping: ⌘5 with three sessions open
    /// should do nothing, not silently select the last one — a shortcut that lands
    /// somewhere unexpected in a terminal is worse than one that does nothing.
    func session(atOneBasedIndex index: Int) -> TerminalSession? {
        guard index >= 1, index <= sessions.count else { return nil }
        return sessions[index - 1]
    }

    /// The session `delta` places from the given one, wrapping at both ends.
    func session(after id: TerminalSession.ID?, delta: Int) -> TerminalSession? {
        guard !sessions.isEmpty else { return nil }
        guard let id, let current = sessions.firstIndex(where: { $0.id == id }) else {
            return delta >= 0 ? sessions.first : sessions.last
        }
        let next = (current + delta % sessions.count + sessions.count) % sessions.count
        return sessions[next]
    }

    /// Sessions for a given host, so the host list can show what is already open.
    func sessions(for host: Host) -> [TerminalSession] {
        sessions.filter { $0.host.id == host.id }
    }
}
