import FileProvider
import Foundation
import Observation
import STCore
import STFileProvider
import STSSH

/// Publishes connections to the Files app, and keeps the system's idea of them in step
/// with the host list (D-044).
///
/// Two things have to agree: the list of `NSFileProviderDomain`s the system knows about,
/// and the records in the shared container the extension reads. This is the only writer
/// of either, and it reconciles both from the host list rather than trying to apply
/// individual edits — a connection that was deleted while the app was not running, or a
/// domain left behind by a crash, is then corrected on the next launch instead of
/// lingering in the sidebar forever.
@Observable
@MainActor
final class FileProviderDomains {
    /// Why a connection cannot be published, for the connections the user has asked
    /// about. Populated by ``refresh()``; a connection missing from the map is fine.
    private(set) var blocked: [Host.ID: DomainPublishability] = [:]
    /// Set when the shared container is unreachable, which makes the whole feature
    /// unavailable rather than silently broken.
    private(set) var unavailableReason: String?

    private let hostStore: HostStore
    private let vault: CredentialVault
    private let knownHosts: any KnownHostsStore
    private let log: STLogger
    private let store: SharedDomainStore?

    init(hostStore: HostStore, vault: CredentialVault, knownHosts: any KnownHostsStore, log: STLogger) {
        self.hostStore = hostStore
        self.vault = vault
        self.knownHosts = knownHosts
        self.log = log.child(subsystem: "files.domains")
        store = SharedDomainStore.shared()
        if store == nil {
            unavailableReason = String(localized: "This build cannot reach its shared storage, so servers cannot appear in Files.")
        }
    }

    var isAvailable: Bool { store != nil }

    /// Whether a connection could be published, and if not, why.
    ///
    /// Everything here is about what the extension can do with nobody present: it cannot
    /// ask for a user name, cannot show a fingerprint, and cannot raise a Face ID sheet.
    /// A connection that needs any of those is refused now, with a reason, rather than
    /// published and then failing in Files where the explanation would be a spinner.
    func publishability(of host: Host) async -> DomainPublishability {
        guard !host.username.trimmingCharacters(in: .whitespaces).isEmpty else { return .needsUsername }
        guard (try? await knownHosts.entry(for: host.knownHostIdentity)) != nil else { return .hostKeyNotApproved }
        guard !usableCredentials(of: host).isEmpty else { return .needsInteractiveCredential }
        return .publishable
    }

    /// Turns publishing on or off for one connection, and applies it immediately.
    func setPublished(_ published: Bool, for host: Host) async {
        var host = host
        host.showsInFiles = published ? true : nil
        hostStore.update(host)
        await refresh()
    }

    /// Makes the system's domains and the extension's records match the host list.
    func refresh() async {
        guard let store else { return }
        var records: [SharedDomain] = []
        var reasons: [Host.ID: DomainPublishability] = [:]
        for host in hostStore.hosts where host.isPublishedToFiles {
            let verdict = await publishability(of: host)
            guard verdict == .publishable else {
                reasons[host.id] = verdict
                continue
            }
            records.append(record(for: host))
        }
        blocked = reasons

        do {
            // Records first: a domain the system can see before its record exists would
            // answer its first enumeration with "this server is no longer set up".
            try store.save(records)
            try await reconcileDomains(with: records)
        } catch {
            log.error("could not publish domains", ["error": String(describing: error)])
        }
    }

    private func reconcileDomains(with records: [SharedDomain]) async throws {
        let existing = try await NSFileProviderManager.domains()
        let wanted = Dictionary(records.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })

        for domain in existing where wanted[domain.identifier.rawValue] == nil {
            // Either the user turned it off, or the connection is gone. Removing the
            // domain is what takes it out of the Files sidebar.
            try await NSFileProviderManager.remove(domain)
            log.info("withdrew a domain", ["domain": domain.identifier.rawValue])
        }

        let present = Set(existing.map(\.identifier.rawValue))
        for record in records {
            if let domain = existing.first(where: { $0.identifier.rawValue == record.id.uuidString }) {
                // A renamed connection has to be renamed in the sidebar too, and the API
                // has no rename: remove and re-add is the documented way.
                if domain.displayName != record.displayName {
                    try await NSFileProviderManager.remove(domain)
                    try await NSFileProviderManager.add(NSFileProviderDomain(
                        identifier: NSFileProviderDomainIdentifier(record.id.uuidString),
                        displayName: record.displayName
                    ))
                }
                continue
            }
            guard !present.contains(record.id.uuidString) else { continue }
            try await NSFileProviderManager.add(NSFileProviderDomain(
                identifier: NSFileProviderDomainIdentifier(record.id.uuidString),
                displayName: record.displayName
            ))
            log.info("published a domain", ["domain": record.displayName])
        }
    }

    /// Tells the system a folder's contents changed, so Files notices work the app did.
    ///
    /// Without this, a file uploaded in the app's own browser would not appear in Files
    /// until the user pulled to refresh — the same folder, two answers.
    func signalChange(for hostID: Host.ID) async {
        guard let manager = NSFileProviderManager(for: NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(hostID.uuidString),
            displayName: ""
        )) else { return }
        try? await manager.signalEnumerator(for: .workingSet)
    }

    private func record(for host: Host) -> SharedDomain {
        SharedDomain(
            id: host.id,
            displayName: host.name,
            hostname: host.hostname,
            port: host.port,
            username: host.username,
            transport: {
                switch host.transport {
                case .directTCP: .directTCP
                case let .cloudflare(jump): .cloudflare(jumpDestination: jump)
                }
            }(),
            credentials: usableCredentials(of: host)
        )
    }

    /// The credentials the extension could actually use, in the order the host offers
    /// them. A key behind Face ID or a passphrase is dropped here rather than published
    /// and refused later.
    private func usableCredentials(of host: Host) -> [SharedDomain.Credential] {
        host.credentials.compactMap { reference in
            switch reference {
            case let .privateKey(id):
                guard let key = hostStore.key(withID: id),
                      !key.requiresBiometrics,
                      !key.isPassphraseProtected,
                      vault.hasPrivateKey(id: id)
                else { return nil }
                return .privateKey(id: id)
            case .password:
                guard ((try? vault.loadPassword(hostID: host.id)) ?? nil) != nil else { return nil }
                return .storedPassword
            case .none:
                return nil
            }
        }
    }
}

extension DomainPublishability {
    /// What the user is told, in the place the toggle is.
    var explanation: String? {
        switch self {
        case .publishable:
            nil
        case .needsUsername:
            String(localized: "Add a user name to this connection first. The Files app cannot ask for one.")
        case .needsInteractiveCredential:
            String(localized: "Save a password, or use a key without a passphrase and without Face ID. The Files app cannot ask for either.")
        case .hostKeyNotApproved:
            String(localized: "Connect to this server once in Apex Terminal first, so its host key is checked and remembered.")
        }
    }
}
