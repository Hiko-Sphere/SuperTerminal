import Foundation
import Observation
import STCore

/// Stores the host list and the key catalogue.
///
/// Both are non-secret metadata, so they live in a JSON file in the app container with
/// complete file protection. The secrets they refer to are in the Keychain; keeping the
/// split explicit is what makes "export my hosts" a safe feature to offer later.
@Observable
@MainActor
final class HostStore {
    private(set) var hosts: [Host] = []
    /// Where deletions are remembered for sync. Set by the container; nil in a store
    /// that is not synchronised, in which case a deletion is simply a deletion.
    var tombstones: SyncTombstones?
    private(set) var keys: [StoredKey] = []
    private(set) var loadError: STError?

    private let hostsURL: URL
    private let keysURL: URL

    init(directory: URL) {
        hostsURL = directory.appendingPathComponent("hosts.json")
        keysURL = directory.appendingPathComponent("keys.json")
        load()
    }

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SuperTerminal", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    // MARK: - Hosts

    /// `stamping` is false only when the record arrived from another device and already
    /// carries the time it changed there; stamping it again would make this device the
    /// newer writer and echo it straight back.
    func add(_ host: Host, stamping: Bool = true) {
        var host = host
        if stamping { host.modifiedAt = Date() }
        hosts.append(host)
        sortHosts()
        persistHosts()
    }

    func update(_ host: Host, stamping: Bool = true) {
        guard let index = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        var host = host
        if stamping { host.modifiedAt = Date() }
        hosts[index] = host
        sortHosts()
        persistHosts()
    }

    /// `recordingTombstone` is false when the deletion itself came from sync: a tombstone
    /// for it already exists on the device that deleted it.
    func remove(_ host: Host, recordingTombstone: Bool = true) {
        hosts.removeAll { $0.id == host.id }
        if recordingTombstone { tombstones?.record(SyncKey(kind: .host, id: host.id.uuidString)) }
        persistHosts()
    }

    func markConnected(_ host: Host, at date: Date = Date()) {
        guard let index = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        hosts[index].lastConnected = date
        persistHosts()
    }

    var folders: [String] {
        Array(Set(hosts.compactMap(\.folder))).sorted()
    }

    // MARK: - Keys

    func add(_ key: StoredKey, stamping: Bool = true) {
        var key = key
        if stamping { key.modifiedAt = Date() }
        keys.append(key)
        keys.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        persistKeys()
    }

    /// Insert or replace a key's metadata as it arrived from another device. Metadata
    /// only: the private key itself is never in this store.
    func upsert(_ key: StoredKey) {
        if let index = keys.firstIndex(where: { $0.id == key.id }) {
            keys[index] = key
            keys.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            persistKeys()
        } else {
            add(key, stamping: false)
        }
    }

    func remove(keyID: UUID, recordingTombstone: Bool = true) {
        keys.removeAll { $0.id == keyID }
        if recordingTombstone { tombstones?.record(SyncKey(kind: .keyMetadata, id: keyID.uuidString)) }
        // A host that referenced the deleted key must stop referencing it, or the next
        // connection would fail with a confusing "credential not found".
        for index in hosts.indices {
            hosts[index].credentials.removeAll { $0 == .privateKey(id: keyID) }
        }
        persistKeys()
        persistHosts()
    }

    func key(withID id: UUID) -> StoredKey? {
        keys.first { $0.id == id }
    }

    /// Removes every host and key record. Callers are responsible for clearing the
    /// corresponding Keychain items; this only handles the metadata.
    func removeAll() {
        hosts = []
        keys = []
        persistHosts()
        persistKeys()
    }

    // MARK: - Persistence

    private func sortHosts() {
        hosts.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            if FileManager.default.fileExists(atPath: hostsURL.path) {
                hosts = try decoder.decode([Host].self, from: Data(contentsOf: hostsURL))
            }
            if FileManager.default.fileExists(atPath: keysURL.path) {
                keys = try decoder.decode([StoredKey].self, from: Data(contentsOf: keysURL))
            }
        } catch {
            // A corrupt file must not silently wipe the user's hosts, so the existing
            // file is left alone and the problem is surfaced instead.
            loadError = STError(
                category: .internalError,
                message: String(localized: "Your saved connections could not be read."),
                recoverySuggestion: String(localized: "Your data has been left untouched. Reinstalling will clear it if you want to start over."),
                underlyingDescription: String(describing: error)
            )
        }
    }

    /// Fired after any host or key change, so sync can follow edits without polling.
    var didChange: (() -> Void)?

    private func persistHosts() { persist(hosts, to: hostsURL); didChange?() }
    private func persistKeys() { persist(keys, to: keysURL); didChange?() }

    private func persist(_ value: some Encodable, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(value)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            loadError = STError(
                category: .internalError,
                message: String(localized: "Changes could not be saved."),
                underlyingDescription: String(describing: error)
            )
        }
    }
}
