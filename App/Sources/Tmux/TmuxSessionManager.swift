import Foundation
import Observation
import STCore
import STSSH

/// The tmux sessions this app has open, one per connection that asked for tmux.
///
/// One per *connection*, not one per window: tmux's windows live inside the session it
/// attaches to, and opening the same connection twice should find the work that is already
/// there rather than start a second copy of it.
@MainActor
@Observable
final class TmuxSessionManager {
    private(set) var sessions: [TmuxSession] = []

    private let log: STLogger
    /// Builds the connector for a host — the same one terminals use, so a tmux session gets
    /// Cloudflare, jump hosts, certificates, the agent and the shared connection pool
    /// without knowing about any of them.
    var connectorForHost: @MainActor (Host) -> (connector: HostConnector, prompts: PromptCoordinator)?

    init(
        log: STLogger = .disabled,
        connectorForHost: @escaping @MainActor (Host) -> (connector: HostConnector, prompts: PromptCoordinator)? = { _ in nil }
    ) {
        self.log = log
        self.connectorForHost = connectorForHost
    }

    func session(withID id: UUID?) -> TmuxSession? {
        guard let id else { return nil }
        return sessions.first { $0.id == id }
    }

    /// The session for a host, opening one if there is none.
    @discardableResult
    func open(_ host: Host) -> TmuxSession? {
        if let existing = sessions.first(where: { $0.host.id == host.id }) { return existing }
        guard let made = connectorForHost(host) else {
            log.error("no connector for a tmux session")
            return nil
        }
        let session = TmuxSession(host: host, connector: made.connector, prompts: made.prompts, log: log)
        sessions.append(session)
        return session
    }

    func close(_ session: TmuxSession) {
        sessions.removeAll { $0.id == session.id }
        Task { await session.detach() }
    }

    func closeAll() {
        let open = sessions
        sessions.removeAll()
        Task { for session in open { await session.detach() } }
    }
}
