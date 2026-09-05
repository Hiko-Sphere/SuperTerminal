import Foundation
import STSSH
import Testing
@testable import SuperTerminal

/// The adapter between the app's stores and the sync engine — and, first, the migration it
/// depends on: files written before sync existed must still load.
@Suite("App sync store")
@MainActor
struct AppSyncStoreTests {
    private func makeStores() -> (HostStore, SnippetStore, InMemoryKnownHostsStore, SyncTombstones, AppSyncStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("st-sync-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = AppSettings(defaults: UserDefaults(suiteName: "sync-\(UUID())")!)
        let hosts = HostStore(directory: directory)
        let snippets = SnippetStore(directory: directory, settings: settings)
        let known = InMemoryKnownHostsStore()
        let tombstones = SyncTombstones(directory: directory)
        hosts.tombstones = tombstones
        snippets.tombstones = tombstones
        return (hosts, snippets, known, tombstones, AppSyncStore(hosts: hosts, snippets: snippets, knownHosts: known, tombstones: tombstones), directory)
    }

    private func host(_ name: String) -> Host {
        Host(name: name, hostname: "example.invalid", username: "u", credentials: [.none])
    }

    // MARK: Migration

    @Test("A host written before sync existed still decodes")
    func preSyncHostDecodes() throws {
        // The exact shape hosts.json had: no modifiedAt. A synthesized decoder throws on a
        // missing key unless the property is optional, and every existing user's file
        // would then fail to load on the first launch after this change.
        let json = """
        {"id":"11111111-1111-4111-8111-111111111111","name":"Old","hostname":"h","port":22,
         "username":"u","transport":{"directTCP":{}},"credentials":[],"tags":[],
         "terminalType":"xterm-256color","environment":{}}
        """
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Host.self, from: Data(json.utf8))
        #expect(decoded.name == "Old")
        #expect(decoded.modifiedAt == nil, "never stamped, which sync treats as older than anything")
    }

    @Test("A snippet written before sync existed still decodes")
    func preSyncSnippetDecodes() throws {
        let json = """
        {"id":"22222222-2222-4222-8222-222222222222","name":"Disk","command":"df -h",
         "runsImmediately":false,"createdAt":"2026-01-01T00:00:00Z","useCount":0}
        """
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Snippet.self, from: Data(json.utf8))
        #expect(decoded.command == "df -h")
        #expect(decoded.modifiedAt == nil)
    }

    // MARK: Stamping and tombstones

    @Test("Adding or editing stamps the record; a remote apply does not re-stamp")
    func stampingRules() async throws {
        let (hosts, _, _, _, store, dir) = makeStores()
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = host("A")
        hosts.add(h)
        let stamped = hosts.hosts[0].modifiedAt
        #expect(stamped != nil)

        // A record from another device carries its own time; keeping it is what stops
        // this device from becoming the newer writer and echoing it straight back.
        let remoteTime = Date(timeIntervalSince1970: 1_000)
        var remote = h; remote.name = "A from elsewhere"
        let payload = try JSONEncoder.iso.encode(remote)
        try await store.apply(SyncRecord(kind: .host, id: h.id.uuidString, payload: payload, modifiedAt: remoteTime, deleted: false))
        #expect(hosts.hosts[0].name == "A from elsewhere")
        #expect(hosts.hosts[0].modifiedAt == remoteTime)
    }

    @Test("Deleting a host leaves a tombstone that travels")
    func deletionLeavesTombstone() async {
        let (hosts, _, _, tombstones, store, dir) = makeStores()
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = host("Doomed")
        hosts.add(h)
        hosts.remove(h)
        #expect(tombstones.all.count == 1)
        let records = await store.localRecords()
        let dead = records.first { $0.kind == .host && $0.id == h.id.uuidString }
        #expect(dead?.deleted == true, "the deletion must be visible to sync, or another device hands the host back")
    }

    @Test("A deletion that came from sync does not create a second tombstone")
    func remoteDeletionIsNotReTombstoned() async throws {
        let (hosts, _, _, tombstones, store, dir) = makeStores()
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = host("Gone elsewhere")
        hosts.add(h)
        try await store.apply(SyncRecord(kind: .host, id: h.id.uuidString, payload: Data(), modifiedAt: Date(), deleted: true))
        #expect(hosts.hosts.isEmpty)
        #expect(tombstones.all.isEmpty, "the deleting device already holds the tombstone")
    }

    @Test("A tombstone is forgotten when the record comes back")
    func resurrectionClearsTombstone() async throws {
        let (hosts, _, _, tombstones, store, dir) = makeStores()
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = host("Back")
        hosts.add(h); hosts.remove(h)
        #expect(tombstones.all.count == 1)
        let payload = try JSONEncoder.iso.encode(h)
        try await store.apply(SyncRecord(kind: .host, id: h.id.uuidString, payload: payload, modifiedAt: Date(), deleted: false))
        #expect(tombstones.all.isEmpty)
        #expect(hosts.hosts.count == 1)
    }

    // MARK: Known hosts

    @Test("A known-host identity round-trips, including a bastion hop and an IPv6 literal")
    func knownHostIdentityRoundTrips() {
        for identity in [
            KnownHostIdentity(host: "example.org", port: 22, jumpDestination: nil),
            KnownHostIdentity(host: "example.org", port: 2222, jumpDestination: "internal:22"),
            KnownHostIdentity(host: "2001:db8::1", port: 22, jumpDestination: nil),
        ] {
            let id = AppSyncStore.knownHostID(identity)
            #expect(AppSyncStore.knownHostIdentity(id) == identity, "\(id)")
        }
    }

    @Test("The trusted key reported for a host is the key alone")
    func trustedKeyIsKeyOnly() async throws {
        let (_, _, known, _, store, dir) = makeStores()
        defer { try? FileManager.default.removeItem(at: dir) }
        let identity = KnownHostIdentity(host: "example.org", port: 22, jumpDestination: nil)
        let key = SSHHostKey(algorithm: "ssh-ed25519", blob: Data(repeating: 7, count: 32))
        try await known.store(KnownHostEntry(identity: identity, key: key, firstSeen: Date(timeIntervalSince1970: 1), lastSeen: Date(timeIntervalSince1970: 2)))
        let reported = await store.trustedHostKeyPayload(for: AppSyncStore.knownHostID(identity))
        // The engine compares this against a remote record's key; lastSeen must not be in
        // it, or every device with a different last-connection time would look like a
        // changed host key.
        let expected = try JSONEncoder.iso.encode(key)
        #expect(reported == expected)
    }

    @Test("Key metadata carries no secret, by construction")
    func keyMetadataHasNoSecret() throws {
        let key = StoredKey(name: "k", algorithm: "ssh-ed25519", publicKeyOpenSSH: "ssh-ed25519 AAAA test",
                            fingerprintSHA256: "SHA256:abc", createdAt: Date(), requiresBiometrics: false, isPassphraseProtected: false)
        let payload = try JSONEncoder.iso.encode(key)
        let text = String(decoding: payload, as: UTF8.self)
        #expect(!text.contains("PRIVATE"), "the private half never enters a sync payload")
    }
}

private extension JSONEncoder {
    /// Mirrors the adapter's canonical form. Without `.sortedKeys`, Foundation emits keys in
    /// per-process hash order, and this expectation matched the adapter only by chance —
    /// it failed in one simulator clone and passed in the other.
    static var iso: JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
    }
}
