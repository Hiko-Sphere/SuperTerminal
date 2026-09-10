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
        #if targetEnvironment(macCatalyst)
        unavailableReason = Self.macFinderNote
        #else
        if store == nil {
            unavailableReason = String(localized: "This build cannot reach its shared storage, so servers cannot appear in Files.")
        }
        #endif
    }

    /// What a Mac user is told where the switch would have been.
    ///
    /// Declared on every platform, and used only on the one where it is true: a string inside
    /// `#if targetEnvironment(macCatalyst)` is never extracted by an iOS build, so it would
    /// never reach the translators and a Chinese-speaking Mac user would read English (D-070).
    static var macFinderNote: String {
        String(localized: "On the Mac, servers cannot be added to Finder from this app. The system's replicated File Provider is not available to a Mac Catalyst app, so this switch would do nothing. The app's own file browser works here in full.")
    }

    /// What a person is told where the system refuses to keep a domain replicated.
    static var notReplicatedNote: String {
        String(localized: "This system cannot serve a server through the Files app: it has no file-provider storage to put the files in, so the system takes the connection back as soon as it is added. Everything in the app's own file browser still works. On a device this does not happen.")
    }

    /// Set once the system has been seen to downgrade a domain. Nothing is published after
    /// that, for as long as the app is running (D-073).
    private var systemRefusesReplicatedDomains = false

    /// Whether a server can be put in the system's file browser at all.
    ///
    /// False on Mac Catalyst, and not as an omission: `NSFileProviderManager` and everything
    /// around it are marked unavailable there, and the Mac's Finder integration is a different
    /// extension point on a different kind of target. The switch says so rather than sitting
    /// there doing nothing (D-070).
    var isAvailable: Bool {
        #if targetEnvironment(macCatalyst)
        false
        #else
        store != nil && !systemRefusesReplicatedDomains
        #endif
    }

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
        #if targetEnvironment(macCatalyst)
        // The records are still written above: the app's own file browser reads them, and a
        // Mac build that stopped recording which servers were chosen would forget the choice.
        _ = records
        #else
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
        try await withdrawDomainsTheSystemWouldNotKeepReplicated()
        #endif
    }

    /// Takes back any domain the system did not actually make replicated (D-073).
    ///
    /// This is a guard, not the fix. The reason domains were being downgraded was a missing
    /// `NSExtensionFileProviderSupportsEnumeration` in the extension's Info.plist, and that
    /// is fixed there — but the consequence of a downgrade is severe enough to be worth
    /// catching whatever causes it: the system serves a downgraded domain through the
    /// pre-replicated API, this extension implements only the replicated one, and the
    /// framework's answer to being asked anyway is `abort()`, in
    /// `__FILEPROVIDER_V2_EXTENSION_WITHOUT_IMPL`. A server left in the Files sidebar in that
    /// state cannot be opened and kills the extension process on every attempt.
    ///
    /// So a domain that comes back non-replicated is taken away again and the switch says
    /// why. The framework's own header names this read-back as the supported way to ask:
    /// *"users are advised to rely on the output of `getDomainsForProviderIdentifier:`"*.
    private func withdrawDomainsTheSystemWouldNotKeepReplicated() async throws {
        let downgraded = try await NSFileProviderManager.domains().filter { !$0.isReplicated }
        guard !downgraded.isEmpty else { return }
        // Before removing anything: nothing more is published this launch, so a second
        // reconcile cannot put the same domain back and start the cycle again.
        systemRefusesReplicatedDomains = true
        unavailableReason = Self.notReplicatedNote
        for domain in downgraded {
            try? await NSFileProviderManager.remove(domain)
            log.error("withdrew a domain the system would not keep replicated", [
                "domain": domain.identifier.rawValue,
            ])
        }
    }

    /// Tells the system a folder's contents changed, so Files notices work the app did.
    ///
    /// Without this, a file uploaded in the app's own browser would not appear in Files
    /// until the user pulled to refresh — the same folder, two answers.
    func signalChange(for hostID: Host.ID) async {
        #if targetEnvironment(macCatalyst)
        _ = hostID
        #else
        guard let manager = NSFileProviderManager(for: NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(hostID.uuidString),
            displayName: ""
        )) else { return }
        try? await manager.signalEnumerator(for: .workingSet)
        #endif
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

    /// What the published record will list for this connection. Exposed so a test can
    /// check *which* credential was published, not merely that publishing was allowed —
    /// the two have been different before.
    func publishedCredentials(of host: Host) -> [SharedDomain.Credential] {
        usableCredentials(of: host)
    }

    /// The credentials the extension could actually use, in the order the host offers
    /// them. A key behind Face ID or a passphrase is dropped here rather than published
    /// and refused later.
    private func usableCredentials(of host: Host) -> [SharedDomain.Credential] {
        host.credentials.compactMap { reference in
            switch reference {
            case let .privateKey(id):
                guard let key = hostStore.key(withID: id), !key.requiresBiometrics else { return nil }
                if key.isHeldInSecureEnclave {
                    // An enclave key whose policy is "while the device is unlocked" signs
                    // without anyone present, so it belongs in Files like any other. One
                    // that asks for Face ID has already been dropped by the check above.
                    guard vault.hasSecureEnclaveKey(id: id) else { return nil }
                    return .secureEnclaveKey(id: id)
                }
                guard !key.isPassphraseProtected, vault.hasPrivateKey(id: id) else { return nil }
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
