import CoreSpotlight
import Foundation
import STCore
import UniformTypeIdentifiers

/// Puts saved connections in Spotlight, when the person asked for that (D-061).
///
/// What goes in is what is already on the connection list's rows — the name and the
/// address — and nothing else: no credentials, no key names, no host keys. The index is
/// on the device and never leaves it, but it *is* readable by anyone holding the unlocked
/// device without opening this app, which is why the switch exists and why it is off until
/// somebody turns it on.
///
/// Turning it off removes what was indexed rather than leaving it behind, which is the
/// difference between a preference and a promise.
@MainActor
final class SpotlightIndexer {
    /// The activity type Spotlight uses when a result is tapped, and the domain everything
    /// here is filed under so it can be removed in one go.
    static let domain = "dev.apexterminal.connections"

    private let index: CSSearchableIndex
    private let log: STLogger

    init(index: CSSearchableIndex = .default(), log: STLogger = .disabled) {
        self.index = index
        self.log = log
    }

    /// Brings the index in line with what is saved, or empties it.
    func update(hosts: [Host], enabled: Bool) {
        guard enabled else {
            removeEverything()
            return
        }
        let items = hosts.map(Self.item(for:))
        index.indexSearchableItems(items) { [log] error in
            if let error {
                log.info("connections could not be indexed", ["error": String(describing: error)])
            }
        }
    }

    func removeEverything() {
        index.deleteSearchableItems(withDomainIdentifiers: [Self.domain]) { [log] error in
            if let error {
                log.info("indexed connections could not be removed", ["error": String(describing: error)])
            }
        }
    }

    /// The host a Spotlight result stands for.
    static func hostID(for identifier: String) -> UUID? { UUID(uuidString: identifier) }

    static func item(for host: Host) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.title = host.name
        // The same subtitle the row shows: user@host:port. Enough to tell two servers
        // apart, and nothing that is not already on screen in the app.
        attributes.contentDescription = host.subtitle
        attributes.keywords = ["ssh", "terminal", host.hostname]
        let item = CSSearchableItem(
            uniqueIdentifier: host.id.uuidString,
            domainIdentifier: domain,
            attributeSet: attributes
        )
        // No expiry: a connection is indexed for as long as it is saved, and removed when
        // it is not.
        item.expirationDate = .distantFuture
        return item
    }
}
