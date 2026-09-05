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

    func add(_ host: Host) {
        hosts.append(host)
        sortHosts()
        persistHosts()
    }

    func update(_ host: Host) {
        guard let index = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        hosts[index] = host
        sortHosts()
        persistHosts()
    }

    func remove(_ host: Host) {
        hosts.removeAll { $0.id == host.id }
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

    func add(_ key: StoredKey) {
        keys.append(key)
        keys.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        persistKeys()
    }

    func remove(keyID: UUID) {
        keys.removeAll { $0.id == keyID }
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

    private func persistHosts() { persist(hosts, to: hostsURL) }
    private func persistKeys() { persist(keys, to: keysURL) }

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
