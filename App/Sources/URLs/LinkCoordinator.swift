import CoreSpotlight
import Foundation
import Observation
import STCore

/// Turns a link into something the app does — after asking, whenever asking is warranted
/// (D-061).
///
/// Kept apart from the views because the decision matters more than the presentation: a
/// link is untrusted input, and the rule for what may happen without a person's say-so is
/// one thing that should be readable in one place and tested on its own.
@MainActor
@Observable
final class LinkCoordinator {
    /// A link waiting for an answer. The view shows exactly this and nothing it inferred.
    struct Pending: Identifiable, Equatable {
        let id = UUID()
        let link: IncomingURL
        let reason: IncomingURL.Reason
        /// The connection it would use, when the link names one that exists.
        let existing: Host?
        /// What the link says to run, shown verbatim.
        let command: String?
        /// The server as it will be connected to, for a link that names an address.
        let address: IncomingURL.SSHAddress?

        static func == (lhs: Pending, rhs: Pending) -> Bool { lhs.id == rhs.id }
    }

    /// What the app should do now.
    enum Outcome: Equatable {
        /// Open this saved connection.
        case open(hostID: UUID)
        /// Open this saved connection and run something on it.
        case openAndRun(hostID: UUID, command: String)
        /// Offer to add a server the device does not have, with the fields filled in.
        case offerToAdd(IncomingURL.SSHAddress)
        /// The link asked for something this app cannot do.
        case ignored
    }

    private(set) var pending: Pending?
    /// Set when a link has been authorised and is waiting for the interface to act on it.
    private(set) var ready: Outcome?

    private let hosts: () -> [Host]
    private let log: STLogger

    init(hosts: @escaping () -> [Host], log: STLogger = .disabled) {
        self.hosts = hosts
        self.log = log
    }

    /// Takes a link. Either it becomes something to do, or a question to ask.
    func receive(_ url: URL) {
        guard let link = IncomingURL(url) else {
            log.info("a link this app has nothing to do with was ignored")
            return
        }
        let existing = match(link)
        switch link.authorisation(isSaved: existing != nil) {
        case .openDirectly:
            guard let existing else { return }
            ready = .open(hostID: existing.id)
        case let .confirm(reason):
            pending = Pending(
                link: link,
                reason: reason,
                existing: existing,
                command: link.command,
                address: { if case let .address(address) = link { return address } else { return nil } }()
            )
        }
    }

    /// The person said yes, having seen what it does.
    func approvePending() {
        guard let pending else { return }
        self.pending = nil
        switch pending.link {
        case let .savedConnection(_, command):
            guard let host = pending.existing else {
                // A saved connection that has gone between the link arriving and the answer.
                log.info("a link named a connection that no longer exists")
                ready = .ignored
                return
            }
            ready = command.map { .openAndRun(hostID: host.id, command: $0) } ?? .open(hostID: host.id)
        case let .address(address):
            if let host = pending.existing {
                ready = address.command.map { .openAndRun(hostID: host.id, command: $0) } ?? .open(hostID: host.id)
            } else {
                // A server this device does not have is *offered*, not added: the link says
                // where to connect, and adding it silently would leave a connection in the
                // list that nobody typed.
                ready = .offerToAdd(address)
            }
        }
    }

    func dismissPending() {
        pending = nil
    }

    /// Called by the interface once it has acted.
    func consumeReady() -> Outcome? {
        defer { ready = nil }
        return ready
    }

    /// A connection chosen in Spotlight, or handed over from another device (D-061).
    ///
    /// Opened without a question: unlike a link, this is not something that arrived from
    /// somewhere unknown — a search result is one the person picked out of their own
    /// connections, and a handoff comes from a device signed in as them. Neither can carry
    /// a command.
    func receive(activity: NSUserActivity) {
        guard let id = Self.hostID(from: activity) else {
            log.info("an activity with nothing to open was ignored")
            return
        }
        guard hosts().contains(where: { $0.id == id }) else {
            // Handed over from a device that has a connection this one does not. Nothing is
            // invented: sync is not available, so the honest answer is to say so rather
            // than to open something else.
            log.info("an activity named a connection this device does not have")
            ready = .ignored
            return
        }
        ready = .open(hostID: id)
    }

    /// The connection an activity refers to, whichever kind it is.
    static func hostID(from activity: NSUserActivity) -> UUID? {
        if activity.activityType == CSSearchableItemActionType,
           let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String {
            return SpotlightIndexer.hostID(for: identifier)
        }
        if activity.activityType == SessionActivity.type,
           let identifier = activity.userInfo?[SessionActivity.hostKey] as? String {
            return UUID(uuidString: identifier)
        }
        return nil
    }

    /// The saved connection a link names, if any.
    ///
    /// By id first, then by name, then by address — the three ways somebody writing a link
    /// would identify one, in the order of how exactly they identify it.
    func match(_ link: IncomingURL) -> Host? {
        let saved = hosts()
        switch link {
        case let .savedConnection(reference, _):
            if let id = UUID(uuidString: reference), let host = saved.first(where: { $0.id == id }) {
                return host
            }
            return saved.first { $0.name.compare(reference, options: .caseInsensitive) == .orderedSame }
        case let .address(address):
            return saved.first { host in
                host.hostname.compare(address.host, options: .caseInsensitive) == .orderedSame
                    && (address.port == nil || host.port == address.port)
                    && (address.username == nil || host.username == address.username)
            }
        }
    }
}
