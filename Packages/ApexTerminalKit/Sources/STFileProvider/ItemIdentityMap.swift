import Foundation

/// Gives every remote path a File Provider identifier that survives a rename.
///
/// SFTP version 3 has no stable identity for a file: it names things by path, and a
/// rename produces a path nobody has seen before. The File Provider API needs the
/// opposite — an identifier that does not change when a file moves, because it is what
/// the system's own database is keyed on. Deriving the identifier from the path (a hash,
/// or the path itself) would mean every rename looked like a delete followed by an
/// unrelated create, losing the file's local state and any download of its contents.
///
/// So identity is assigned here and remembered. A rename moves the identifier to the new
/// path, and a directory rename carries its whole subtree with it — otherwise the
/// children would still claim to live under a directory that no longer exists.
///
/// The map is per domain and lives in the shared container, so it is the same map on the
/// next launch of an extension the system may kill at any time.
public actor ItemIdentityMap {
    private let url: URL
    private var pathByIdentifier: [String: String] = [:]
    private var identifierByPath: [String: String] = [:]
    private var loaded = false

    public init(url: URL) {
        self.url = url
    }

    /// The store for one domain inside a container directory.
    public static func forDomain(id: UUID, in container: URL) -> ItemIdentityMap {
        ItemIdentityMap(url: container
            .appendingPathComponent("FileProvider", isDirectory: true)
            .appendingPathComponent("identity-\(id.uuidString).json"))
    }

    /// The identifier for a path, allocating one the first time the path is seen.
    public func identifier(forPath path: String) -> String {
        load()
        let path = Self.normalized(path)
        if let existing = identifierByPath[path] { return existing }
        let identifier = UUID().uuidString
        identifierByPath[path] = identifier
        pathByIdentifier[identifier] = path
        persist()
        return identifier
    }

    public func path(for identifier: String) -> String? {
        load()
        return pathByIdentifier[identifier]
    }

    /// Moves `from` — and everything beneath it — to `to`, keeping every identifier.
    public func move(from: String, to: String) {
        load()
        let from = Self.normalized(from)
        let to = Self.normalized(to)
        guard from != to else { return }
        // Anything already sitting at the destination is gone: the caller has just
        // overwritten it on the server, so keeping its identifier would hand the system
        // an identifier for a file that no longer exists.
        forgetSubtree(rootedAt: to)

        let prefix = from + "/"
        for (path, identifier) in identifierByPath where path == from || path.hasPrefix(prefix) {
            let moved = path == from ? to : to + String(path.dropFirst(from.count))
            identifierByPath.removeValue(forKey: path)
            identifierByPath[moved] = identifier
            pathByIdentifier[identifier] = moved
        }
        persist()
    }

    /// Forgets a path and its subtree, after a delete.
    public func forget(_ path: String) {
        load()
        forgetSubtree(rootedAt: Self.normalized(path))
        persist()
    }

    private func forgetSubtree(rootedAt path: String) {
        let prefix = path + "/"
        for (existing, identifier) in identifierByPath where existing == path || existing.hasPrefix(prefix) {
            identifierByPath.removeValue(forKey: existing)
            pathByIdentifier.removeValue(forKey: identifier)
        }
    }

    /// Trailing slashes would make `/tmp` and `/tmp/` two different files.
    static func normalized(_ path: String) -> String {
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([String: String].self, from: data)
        else { return }
        pathByIdentifier = stored
        identifierByPath = Dictionary(stored.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(pathByIdentifier) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Losing this file costs identity, not data: paths are re-learned on the next
        // enumeration. So a failed write is not worth failing the user's operation over.
        #if os(iOS)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try? data.write(to: url, options: [.atomic])
        #endif
    }
}
