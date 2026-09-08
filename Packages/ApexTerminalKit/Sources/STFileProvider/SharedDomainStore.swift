import Foundation
import STCore

/// The App Group both processes agree on.
///
/// It is not a secret and not a capability by itself: without the matching entitlement in
/// both bundles the container simply does not exist, which is why every lookup here can
/// fail and says so rather than trapping.
public enum SharedContainer {
    public static let appGroup = "group.dev.apexterminal.app"

    /// Where the known-host keys live once the File Provider exists.
    ///
    /// In the shared container rather than the app's own, because the extension has to
    /// see exactly the keys the app approved. A mirror would be a second answer to "is
    /// this host trusted", and the whole point of the check is that there is one.
    public static func knownHostsURL(in container: URL) -> URL {
        container.appendingPathComponent("known_hosts.json")
    }

    /// The shared directory, or `nil` when the entitlement is missing.
    ///
    /// A build that lost the App Group must degrade to "Files integration unavailable",
    /// not crash — a provisioning mistake should cost the feature, not the app.
    public static func url(appGroup: String = SharedContainer.appGroup) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }
}

/// The published list of connections that appear in Files.
///
/// Single writer by design: the app writes, the extension only reads. That is what makes
/// an unsynchronised JSON file safe here — the extension can be launched at any moment,
/// several times over, and none of those processes ever touch the file.
public struct SharedDomainStore: Sendable {
    private let url: URL

    public init(directory: URL) {
        url = directory.appendingPathComponent("file-provider-domains.json")
    }

    /// The store in the shared container, or `nil` when the App Group is unavailable.
    public static func shared(appGroup: String = SharedContainer.appGroup) -> SharedDomainStore? {
        guard let container = SharedContainer.url(appGroup: appGroup) else { return nil }
        return SharedDomainStore(directory: container)
    }

    public func load() throws -> [SharedDomain] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([SharedDomain].self, from: Data(contentsOf: url))
    }

    public func domain(id: UUID) throws -> SharedDomain? {
        try load().first { $0.id == id }
    }

    public func save(_ domains: [SharedDomain]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(domains.sorted { $0.id.uuidString < $1.id.uuidString })
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // `completeUntilFirstUserAuthentication` rather than `complete`: the extension is
        // launched by the system at moments the app does not control, and a file it
        // cannot read would look like "this server has no folders" instead of "the device
        // is locked". The secrets it points at are still `whenUnlocked`, so a locked
        // device cannot be browsed — it just fails for the honest reason.
        #if os(iOS)
        let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        let options: Data.WritingOptions = [.atomic]
        #endif
        try data.write(to: url, options: options)
    }
}
