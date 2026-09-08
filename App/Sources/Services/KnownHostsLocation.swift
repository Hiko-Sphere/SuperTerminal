import Foundation
import STCore
import STFileProvider

/// Where the known-host keys live, and the one-time move that put them there (D-044).
///
/// The File Provider extension runs in its own process and must refuse a host the app has
/// not approved — which it can only do if it can read the same record of approvals. So the
/// file moved from the app's container into the shared App Group.
///
/// The move happens once, at launch, before anything reads the store. If the shared
/// container is unavailable the app keeps using its own copy: losing the Files feature is
/// acceptable, forgetting every host key is not.
enum KnownHostsLocation {
    static let fileName = "known_hosts.json"

    static func url(appContainer: URL) -> URL {
        guard let shared = SharedContainer.url() else {
            return appContainer.appendingPathComponent(fileName)
        }
        migrateIfNeeded(from: appContainer.appendingPathComponent(fileName), to: SharedContainer.knownHostsURL(in: shared))
        return SharedContainer.knownHostsURL(in: shared)
    }

    private static func migrateIfNeeded(from legacy: URL, to shared: URL) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: legacy.path) else { return }
        // Already moved: a later launch must not overwrite the shared file with a stale
        // copy that a restored backup could have left behind.
        guard !manager.fileExists(atPath: shared.path) else { return }
        do {
            try manager.createDirectory(at: shared.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.moveItem(at: legacy, to: shared)
        } catch {
            // A failed move leaves the original where it is, which still works for the
            // app. Only the Files feature is affected, and it says so.
        }
    }
}
