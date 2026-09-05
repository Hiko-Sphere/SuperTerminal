import Foundation
import STSSH

/// Deletions the app still remembers, so they can travel.
///
/// Without these, deleting a host on one device would be undone by the next device to
/// sync, which still has it. Kept for thirty days — longer than any device the user still
/// cares about is likely to stay offline.
final class SyncTombstones: @unchecked Sendable {
    struct Tombstone: Codable, Equatable { var key: SyncKey; var deletedAt: Date }
    static let retention: TimeInterval = 30 * 24 * 60 * 60

    private let url: URL
    private let lock = NSLock()
    private var entries: [Tombstone] = []

    init(directory: URL) {
        url = directory.appendingPathComponent("sync_tombstones.json")
        if let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode([Tombstone].self, from: data)
        {
            entries = stored.filter { Date().timeIntervalSince($0.deletedAt) < Self.retention }
        }
    }

    func record(_ key: SyncKey) {
        lock.withLock {
            entries.removeAll { $0.key == key }
            entries.append(Tombstone(key: key, deletedAt: Date()))
            persist()
        }
    }

    func forget(_ key: SyncKey) {
        lock.withLock { entries.removeAll { $0.key == key }; persist() }
    }

    var all: [Tombstone] { lock.withLock { entries } }

    func removeAll() {
        lock.withLock { entries.removeAll(); try? FileManager.default.removeItem(at: url) }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
    }
}

/// The app's stores, presented to the sync engine as opaque records.
///
/// The engine moves payloads; this is where a payload becomes a `Host` again, through the
/// same `Codable` path the app uses for its own files — so a model's validation applies to
/// data from another device exactly as it applies to data typed in here.
///
/// What each kind carries, and what it deliberately does not:
///   * `host` — the connection record. Credential *references* travel; secrets do not.
///   * `keyMetadata` — a key's name, algorithm, public half and fingerprint. **Never the
///     private key.** That travels through iCloud Keychain if the user chose that for the
///     key, and otherwise not at all. This type holds no reference to the vault, so it
///     cannot leak a secret by mistake.
///   * `snippet` — the snippet. Command history is not a snippet and is never here.
///   * `knownHost` — a host key the user has trusted. Applied only when this device has no
///     key for that host or the same key; a *different* key is held by the engine for the
///     changed-key prompt. This store reports what it trusts so the engine can tell.
@MainActor
final class AppSyncStore: SyncLocalStore {
    private let hosts: HostStore
    private let snippets: SnippetStore
    private let knownHosts: any KnownHostsStore
    private let tombstones: SyncTombstones
    /// `.sortedKeys` is load-bearing: the engine detects a changed host key by comparing
    /// this device's payload bytes with another device's, and without a canonical key
    /// order Foundation's output varies from process to process.
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(hosts: HostStore, snippets: SnippetStore, knownHosts: any KnownHostsStore, tombstones: SyncTombstones) {
        self.hosts = hosts
        self.snippets = snippets
        self.knownHosts = knownHosts
        self.tombstones = tombstones
    }

    // MARK: SyncLocalStore

    func localRecords() async -> [SyncRecord] {
        var records: [SyncRecord] = []
        for host in hosts.hosts {
            if let payload = try? encoder.encode(host) {
                records.append(SyncRecord(kind: .host, id: host.id.uuidString, payload: payload,
                                          modifiedAt: host.modifiedAt ?? .distantPast, deleted: false))
            }
        }
        for key in hosts.keys {
            if let payload = try? encoder.encode(key) {
                records.append(SyncRecord(kind: .keyMetadata, id: key.id.uuidString, payload: payload,
                                          modifiedAt: key.modifiedAt ?? .distantPast, deleted: false))
            }
        }
        for snippet in snippets.snippets {
            if let payload = try? encoder.encode(snippet) {
                records.append(SyncRecord(kind: .snippet, id: snippet.id.uuidString, payload: payload,
                                          modifiedAt: snippet.modifiedAt ?? .distantPast, deleted: false))
            }
        }
        if let entries = try? await knownHosts.all() {
            for entry in entries {
                if let payload = try? encoder.encode(entry) {
                    records.append(SyncRecord(kind: .knownHost, id: Self.knownHostID(entry.identity), payload: payload,
                                              modifiedAt: entry.lastSeen, deleted: false))
                }
            }
        }
        // A tombstone for something that exists again — a host key deleted, then trusted
        // again on the next connection — would push a deletion alongside the live record.
        // The live record is the truth; the tombstone is forgotten.
        let live = Set(records.map(\.key))
        for tombstone in tombstones.all {
            if live.contains(tombstone.key) {
                tombstones.forget(tombstone.key)
                continue
            }
            records.append(SyncRecord(kind: tombstone.key.kind, id: tombstone.key.id, payload: Data(),
                                      modifiedAt: tombstone.deletedAt, deleted: true))
        }
        return records
    }

    func apply(_ record: SyncRecord) async throws {
        switch (record.kind, record.deleted) {
        case (.host, true):
            if let id = UUID(uuidString: record.id), let host = hosts.hosts.first(where: { $0.id == id }) {
                hosts.remove(host, recordingTombstone: false)
            }
        case (.host, false):
            var host = try decoder.decode(Host.self, from: record.payload)
            host.modifiedAt = record.modifiedAt
            if hosts.hosts.contains(where: { $0.id == host.id }) {
                hosts.update(host, stamping: false)
            } else {
                hosts.add(host, stamping: false)
            }
            tombstones.forget(record.key)
        case (.keyMetadata, true):
            if let id = UUID(uuidString: record.id) { hosts.remove(keyID: id, recordingTombstone: false) }
        case (.keyMetadata, false):
            var key = try decoder.decode(StoredKey.self, from: record.payload)
            key.modifiedAt = record.modifiedAt
            hosts.upsert(key)
            tombstones.forget(record.key)
        case (.snippet, true):
            if let id = UUID(uuidString: record.id), let snippet = snippets.snippets.first(where: { $0.id == id }) {
                snippets.remove(snippet, recordingTombstone: false)
            }
        case (.snippet, false):
            var snippet = try decoder.decode(Snippet.self, from: record.payload)
            snippet.modifiedAt = record.modifiedAt
            if snippets.snippets.contains(where: { $0.id == snippet.id }) {
                snippets.update(snippet, stamping: false)
            } else {
                snippets.add(snippet, stamping: false)
            }
            tombstones.forget(record.key)
        case (.knownHost, true):
            if let identity = Self.knownHostIdentity(record.id) { try await knownHosts.remove(identity) }
        case (.knownHost, false):
            let entry = try decoder.decode(KnownHostEntry.self, from: record.payload)
            try await knownHosts.store(entry)
            tombstones.forget(record.key)
        }
    }

    func trustedHostKeyPayload(for id: String) async -> Data? {
        guard let identity = Self.knownHostIdentity(id),
              let entry = try? await knownHosts.entry(for: identity)
        else { return nil }
        // The key alone. `lastSeen` differs between devices and is not a reason to treat
        // two identical keys as a conflict.
        return try? encoder.encode(entry.key)
    }

    // MARK: Identity

    /// `host:port`, with `→jump` appended for a bastion hop. The port is the *last* colon
    /// so an IPv6 literal, which contains colons, still parses.
    static func knownHostID(_ identity: KnownHostIdentity) -> String {
        var id = "\(identity.host):\(identity.port)"
        if let jump = identity.jumpDestination { id += "→\(jump)" }
        return id
    }

    static func knownHostIdentity(_ id: String) -> KnownHostIdentity? {
        var main = Substring(id)
        var jump: String?
        if let arrow = id.range(of: "→") {
            main = id[..<arrow.lowerBound]
            jump = String(id[arrow.upperBound...])
        }
        guard let colon = main.lastIndex(of: ":"), let port = Int(main[main.index(after: colon)...]) else { return nil }
        return KnownHostIdentity(host: String(main[..<colon]), port: port, jumpDestination: jump)
    }
}
