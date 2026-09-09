import Foundation
import STCore

/// Persistent record of which host key belongs to which host.
///
/// This is the single most important piece of state in an SSH client: without it,
/// every connection is trust-on-first-use forever and a man-in-the-middle is
/// undetectable. The protocol is deliberately narrow so that the verification policy
/// lives in one place — ``HostKeyVerifier`` — rather than being re-derived by each
/// caller.
public protocol KnownHostsStore: Sendable {
    func entry(for identity: KnownHostIdentity) async throws -> KnownHostEntry?
    func store(_ entry: KnownHostEntry) async throws
    func remove(_ identity: KnownHostIdentity) async throws
    func all() async throws -> [KnownHostEntry]
    /// Forgets every host. "Delete all data" must include host keys: left behind with
    /// sync on, they would be pushed straight back to iCloud.
    func removeAll() async throws
}

/// File-backed ``KnownHostsStore``.
///
/// Host keys are public data, so they live in the app container rather than the
/// Keychain — but the file is written with ``Foundation/Data/WritingOptions/atomicAndProtected``
/// so that on a device it is not readable while the device is locked, and it is excluded from
/// backups so that restoring an old backup cannot silently reinstate a retired key. On a Mac
/// that protection is FileVault's rather than the file's; see the option's own note (D-070).
public actor FileKnownHostsStore: KnownHostsStore {
    private let url: URL
    private var cache: [String: KnownHostEntry]?
    private let log: STLogger

    public init(url: URL, log: STLogger = .disabled) {
        self.url = url
        self.log = log.child(subsystem: "ssh.knownhosts")
    }

    public func entry(for identity: KnownHostIdentity) async throws -> KnownHostEntry? {
        try load()[identity.storageKey]
    }

    public func store(_ entry: KnownHostEntry) async throws {
        var entries = try load()
        entries[entry.identity.storageKey] = entry
        try save(entries)
    }

    public func remove(_ identity: KnownHostIdentity) async throws {
        var entries = try load()
        entries.removeValue(forKey: identity.storageKey)
        try save(entries)
    }

    public func removeAll() async throws {
        try save([:])
    }

    public func all() async throws -> [KnownHostEntry] {
        try load().values.sorted { $0.identity.storageKey < $1.identity.storageKey }
    }

    private func load() throws -> [String: KnownHostEntry] {
        if let cache { return cache }
        guard FileManager.default.fileExists(atPath: url.path) else {
            cache = [:]
            return [:]
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = try decoder.decode([KnownHostEntry].self, from: data)
        let map = Dictionary(entries.map { ($0.identity.storageKey, $0) }, uniquingKeysWith: { _, latest in latest })
        cache = map
        return map
    }

    private func save(_ entries: [String: KnownHostEntry]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries.values.sorted { $0.identity.storageKey < $1.identity.storageKey })
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Complete file protection is iOS data protection. On macOS — where the package's
        // own tests run — the option makes the atomic write fail with EPERM, so it is asked
        // for only where it means something.
        #if os(iOS)
        let options: Data.WritingOptions = .atomicAndProtected
        #else
        let options: Data.WritingOptions = [.atomic]
        #endif
        try data.write(to: url, options: options)
        var resourceURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? resourceURL.setResourceValues(values)
        cache = entries
    }
}

/// In-memory store used by tests and by "incognito" sessions that must not leave a
/// trace on disk. Because it forgets everything on teardown it provides no protection
/// against a substituted key across launches, so it is never the app's default.
public actor InMemoryKnownHostsStore: KnownHostsStore {
    private var entries: [String: KnownHostEntry] = [:]

    public init(seed: [KnownHostEntry] = []) {
        entries = Dictionary(seed.map { ($0.identity.storageKey, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    public func entry(for identity: KnownHostIdentity) async throws -> KnownHostEntry? {
        entries[identity.storageKey]
    }

    public func store(_ entry: KnownHostEntry) async throws {
        entries[entry.identity.storageKey] = entry
    }

    public func remove(_ identity: KnownHostIdentity) async throws {
        entries.removeValue(forKey: identity.storageKey)
    }

    public func removeAll() async throws {
        entries.removeAll()
    }

    public func all() async throws -> [KnownHostEntry] {
        entries.values.sorted { $0.identity.storageKey < $1.identity.storageKey }
    }
}
