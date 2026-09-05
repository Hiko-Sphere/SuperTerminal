import Foundation
import Testing
@testable import SuperTerminal

/// The reconciliation rules, against an in-memory transport.
///
/// This proves the *engine*: what is applied, what is held, what is pushed, what a
/// tombstone does. It does not prove CloudKit, and TEST_REPORT says so. The one rule
/// worth more than all the others is the host-key one, and it is tested from both sides.
@Suite("Sync engine")
@MainActor
struct SyncEngineTests {
    /// A transport that remembers what it was given and hands out what it is told to.
    final class MemoryTransport: SyncTransport, @unchecked Sendable {
        var remote: [SyncRecord] = []
        var pushedBatches: [[SyncRecord]] = []
        var purged = false
        func pullChanges() async throws -> [SyncRecord] { defer { remote = [] }; return remote }
        func push(_ records: [SyncRecord]) async throws -> [SyncKey] { pushedBatches.append(records); return records.map(\.key) }
        func purgeAll() async throws { purged = true }
    }

    /// A local store that is just a dictionary, plus the one trusted host key it holds.
    final class MemoryLocal: SyncLocalStore, @unchecked Sendable {
        var records: [SyncKey: SyncRecord] = [:]
        var trustedHostKeys: [String: Data] = [:]
        var applied: [SyncRecord] = []
        func localRecords() async -> [SyncRecord] { Array(records.values) }
        func apply(_ record: SyncRecord) async throws {
            applied.append(record)
            if record.deleted { records[record.key] = nil } else { records[record.key] = record }
            if record.kind == .knownHost { trustedHostKeys[record.id] = record.deleted ? nil : record.payload }
        }
        func trustedHostKeyPayload(for id: String) async -> Data? { trustedHostKeys[id] }
    }

    private func record(_ kind: SyncKind, _ id: String, _ text: String, at seconds: TimeInterval, deleted: Bool = false) -> SyncRecord {
        SyncRecord(kind: kind, id: id, payload: Data(text.utf8), modifiedAt: Date(timeIntervalSince1970: seconds), deleted: deleted)
    }

    @Test("A newer remote record replaces an older local one")
    func newerRemoteWins() async {
        let transport = MemoryTransport(), local = MemoryLocal()
        local.records[SyncKey(kind: .host, id: "h1")] = record(.host, "h1", "old", at: 100)
        transport.remote = [record(.host, "h1", "new", at: 200)]
        let engine = SyncEngine(transport: transport, local: local)
        await engine.sync()
        #expect(local.records[SyncKey(kind: .host, id: "h1")]?.payload == Data("new".utf8))
        #expect(engine.status == .idle)
    }

    @Test("An older remote record does not overwrite a newer local one")
    func olderRemoteLoses() async {
        let transport = MemoryTransport(), local = MemoryLocal()
        local.records[SyncKey(kind: .host, id: "h1")] = record(.host, "h1", "mine", at: 300)
        transport.remote = [record(.host, "h1", "stale", at: 200)]
        await SyncEngine(transport: transport, local: local).sync()
        #expect(local.records[SyncKey(kind: .host, id: "h1")]?.payload == Data("mine".utf8))
        #expect(local.applied.isEmpty, "nothing should have been applied")
    }

    @Test("A remote tombstone removes the local record")
    func tombstoneDeletes() async {
        let transport = MemoryTransport(), local = MemoryLocal()
        local.records[SyncKey(kind: .snippet, id: "s1")] = record(.snippet, "s1", "df -h", at: 100)
        transport.remote = [record(.snippet, "s1", "", at: 200, deleted: true)]
        await SyncEngine(transport: transport, local: local).sync()
        #expect(local.records[SyncKey(kind: .snippet, id: "s1")] == nil)
    }

    @Test("Local changes are pushed, and not pushed again until they change")
    func pushesOnlyChanges() async {
        let transport = MemoryTransport(), local = MemoryLocal()
        local.records[SyncKey(kind: .snippet, id: "s1")] = record(.snippet, "s1", "uptime", at: 100)
        let engine = SyncEngine(transport: transport, local: local)
        await engine.sync()
        #expect(transport.pushedBatches.count == 1 && transport.pushedBatches[0].count == 1)
        await engine.sync()
        // Unchanged since it was accepted: nothing to send.
        #expect(transport.pushedBatches[1].isEmpty)
        local.records[SyncKey(kind: .snippet, id: "s1")] = record(.snippet, "s1", "uptime -p", at: 150)
        await engine.sync()
        #expect(transport.pushedBatches[2].count == 1)
    }

    @Test("A record applied from remote is not echoed straight back")
    func appliedRecordsAreNotEchoed() async {
        let transport = MemoryTransport(), local = MemoryLocal()
        transport.remote = [record(.host, "h1", "from-other-device", at: 200)]
        await SyncEngine(transport: transport, local: local).sync()
        // Echoing it would make every device re-send everything it received, forever.
        #expect(transport.pushedBatches[0].isEmpty)
    }

    @Test("A different key for a trusted host is held, never applied")
    func differingHostKeyIsHeld() async {
        let transport = MemoryTransport(), local = MemoryLocal()
        let id = "example.org:22"
        local.records[SyncKey(kind: .knownHost, id: id)] = record(.knownHost, id, "KEY-A", at: 100)
        local.trustedHostKeys[id] = Data("KEY-A".utf8)
        transport.remote = [record(.knownHost, id, "KEY-B", at: 999)]
        let engine = SyncEngine(transport: transport, local: local)
        await engine.sync()
        // Newer, and it still loses: sync is a convenience and the host-key check is the
        // security model. The changed-key prompt decides, with the user.
        #expect(local.trustedHostKeys[id] == Data("KEY-A".utf8))
        #expect(engine.conflicts[SyncKey(kind: .knownHost, id: id)]?.reason == .hostKeyDiffers)
        #expect(engine.conflicts[SyncKey(kind: .knownHost, id: id)]?.remote.payload == Data("KEY-B".utf8))
    }

    @Test("The same key for a trusted host is applied without fuss")
    func matchingHostKeyIsApplied() async {
        let transport = MemoryTransport(), local = MemoryLocal()
        let id = "example.org:22"
        local.records[SyncKey(kind: .knownHost, id: id)] = record(.knownHost, id, "KEY-A", at: 100)
        local.trustedHostKeys[id] = Data("KEY-A".utf8)
        transport.remote = [record(.knownHost, id, "KEY-A", at: 200)]
        let engine = SyncEngine(transport: transport, local: local)
        await engine.sync()
        #expect(engine.conflicts.isEmpty)
        #expect(local.applied.count == 1)
    }

    @Test("A host key for a server this device has never seen is simply learned")
    func unknownHostKeyIsLearned() async {
        let transport = MemoryTransport(), local = MemoryLocal()
        transport.remote = [record(.knownHost, "new.example:22", "KEY-N", at: 200)]
        let engine = SyncEngine(transport: transport, local: local)
        await engine.sync()
        #expect(engine.conflicts.isEmpty)
        #expect(local.trustedHostKeys["new.example:22"] == Data("KEY-N".utf8))
    }

    @Test("Resolving a conflict forgets the held record")
    func resolvingClearsConflict() async {
        let transport = MemoryTransport(), local = MemoryLocal()
        let id = "example.org:22"
        local.trustedHostKeys[id] = Data("KEY-A".utf8)
        local.records[SyncKey(kind: .knownHost, id: id)] = record(.knownHost, id, "KEY-A", at: 100)
        transport.remote = [record(.knownHost, id, "KEY-B", at: 999)]
        let engine = SyncEngine(transport: transport, local: local)
        await engine.sync()
        engine.resolveConflict(SyncKey(kind: .knownHost, id: id))
        #expect(engine.conflicts.isEmpty)
    }

    @Test("Purging removes the remote copy and forgets what was pushed")
    func purge() async throws {
        let transport = MemoryTransport(), local = MemoryLocal()
        local.records[SyncKey(kind: .host, id: "h1")] = record(.host, "h1", "x", at: 100)
        let engine = SyncEngine(transport: transport, local: local)
        await engine.sync()
        try await engine.purgeRemote()
        #expect(transport.purged)
        #expect(engine.lastSynced == nil)
        // After a purge the record is unsent again; a later sync must resend it.
        await engine.sync()
        #expect(transport.pushedBatches.last?.count == 1)
    }

    @Test("A transport failure is reported, not swallowed")
    func failureIsReported() async {
        final class FailingTransport: SyncTransport, @unchecked Sendable {
            struct Offline: Error {}
            func pullChanges() async throws -> [SyncRecord] { throw Offline() }
            func push(_ records: [SyncRecord]) async throws -> [SyncKey] { throw Offline() }
            func purgeAll() async throws { throw Offline() }
        }
        let engine = SyncEngine(transport: FailingTransport(), local: MemoryLocal())
        await engine.sync()
        if case .failed = engine.status {} else { Issue.record("expected .failed, got \(engine.status)") }
    }
}
