import Foundation
import STCore
@testable import STSSH
import Testing

/// "Delete all data" removes host keys through `removeAll`; both stores must actually
/// forget them, and the file store must forget them on disk, not just in memory.
@Suite struct KnownHostsRemoveAllTests {
    private func entry(_ host: String) -> KnownHostEntry {
        KnownHostEntry(
            identity: KnownHostIdentity(host: host, port: 22),
            key: SSHHostKey(algorithm: "ssh-ed25519", blob: Data(host.utf8)),
            firstSeen: Date(timeIntervalSince1970: 1),
            lastSeen: Date(timeIntervalSince1970: 2)
        )
    }

    @Test func inMemoryForgetsEverything() async throws {
        let store = InMemoryKnownHostsStore(seed: [entry("a.example"), entry("b.example")])
        #expect(try await store.all().count == 2)
        try await store.removeAll()
        #expect(try await store.all().isEmpty)
        #expect(try await store.entry(for: KnownHostIdentity(host: "a.example", port: 22)) == nil)
    }

    @Test func fileStoreForgetsOnDisk() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("known-hosts-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let log = STLogger(subsystem: "test", sinks: [], minimumLevel: .error)
        let store = FileKnownHostsStore(url: url, log: log)
        try await store.store(entry("a.example"))
        try await store.store(entry("b.example"))
        try await store.removeAll()
        #expect(try await store.all().isEmpty)
        // A fresh store over the same file sees nothing either.
        let reopened = FileKnownHostsStore(url: url, log: log)
        #expect(try await reopened.all().isEmpty)
        #expect(try await reopened.entry(for: KnownHostIdentity(host: "b.example", port: 22)) == nil)
    }
}
