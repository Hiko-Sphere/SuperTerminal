import CloudKit
import Foundation
import Testing

@testable import ApexTerminal

/// Two defects that each make sync fail for ever while looking like the server's fault (D-081).
///
/// Both were found by adversarial review of the claim that the CloudKit container alone was
/// broken. Neither is about CloudKit at all.
@Suite("Sync does not resend what the server already took")
@MainActor
struct SyncResendTests {
    /// Accepts everything, and additionally reports one key that was never sent — which is
    /// what the real transport does, because `CKSyncEngine` also sends on its own schedule
    /// and every acceptance lands in the same list.
    final class ChattyTransport: SyncTransport, @unchecked Sendable {
        var extra: [SyncKey] = []
        var pushedBatches: [[SyncRecord]] = []
        func pullChanges() async throws -> [SyncRecord] { [] }
        func push(_ records: [SyncRecord]) async throws -> [SyncKey] {
            // Only what was actually offered. The real transport returns early on an empty
            // array, so counting empty batches here would measure the stub, not the engine.
            if !records.isEmpty { pushedBatches.append(records) }
            return records.map(\.key) + extra
        }
        func purgeAll() async throws {}
    }

    final class MemoryLocal: SyncLocalStore, @unchecked Sendable {
        var records: [SyncKey: SyncRecord] = [:]
        func localRecords() async -> [SyncRecord] { Array(records.values) }
        func apply(_ record: SyncRecord) async throws { records[record.key] = record }
        func trustedHostKeyPayload(for id: String) async -> Data? { nil }
    }

    private func record(_ id: String, at seconds: TimeInterval) -> SyncRecord {
        SyncRecord(kind: .host, id: id, payload: Data(id.utf8), modifiedAt: Date(timeIntervalSince1970: seconds), deleted: false)
    }

    @Test("A record the engine sent on its own does not lose its pushed stamp")
    func acceptanceOutsideAPushDoesNotResurrectARecord() async {
        let transport = ChattyTransport(), local = MemoryLocal()
        let key = SyncKey(kind: .host, id: "h1")
        local.records[key] = record("h1", at: 100)

        let engine = SyncEngine(transport: transport, local: local)
        await engine.sync()
        #expect(transport.pushedBatches.count == 1)
        #expect(transport.pushedBatches[0].map(\.id) == ["h1"])

        // From here on the transport reports "h1" as accepted on every call, whether or not
        // it was handed over. That is what the real one does: `CKSyncEngine` also sends on
        // its own schedule, every acceptance lands in the same list, and only `push` drains
        // it — so a later push returns keys it never sent.
        //
        // Nothing changed locally, so there is nothing to send. It used to be sent anyway,
        // for ever: `pushed[key] = sentAt[key]` with `sentAt[key]` nil does not store nil,
        // it REMOVES the entry, and the record was un-marked as pushed by its own success.
        transport.extra = [key]

        await engine.sync()
        #expect(
            transport.pushedBatches.count == 1,
            "an unchanged record was offered again: \(transport.pushedBatches.map { $0.map(\.id) })"
        )

        // And a third, because a loop this shape only shows itself on repetition.
        await engine.sync()
        #expect(transport.pushedBatches.count == 1)
    }

    @Test("A record that really did change is still sent again")
    func realChangesStillGo() async {
        let transport = ChattyTransport(), local = MemoryLocal()
        local.records[SyncKey(kind: .host, id: "h1")] = record("h1", at: 100)
        let engine = SyncEngine(transport: transport, local: local)
        await engine.sync()
        #expect(transport.pushedBatches.count == 1)

        // The guard must not become "never send anything twice".
        local.records[SyncKey(kind: .host, id: "h1")] = record("h1", at: 200)
        await engine.sync()
        #expect(transport.pushedBatches.count == 2)
        #expect(transport.pushedBatches[1].map(\.id) == ["h1"])
    }
}

/// The change tag a record carries when it arrived by *fetch* rather than by save (D-081).
///
/// D-075 fixed this on the save path and its own doc comment claimed the fetch path with it.
/// The fetch path was never wired — which is exactly the second device in a two-device setup,
/// the only arrangement in which sync can be verified at all.
@Suite("The server's copy is kept from a fetch too")
struct FetchedRecordTagTests {
    private let zoneID = CKRecordZone.ID(zoneName: "ApexTerminal", ownerName: CKCurrentUserDefaultName)

    private func serverRecord(_ id: String) -> CKRecord {
        let recordID = CloudKitSyncTransport.recordID(for: SyncKey(kind: .host, id: id), zoneID: zoneID)
        let ck = CKRecord(recordType: CloudKitSyncTransport.recordType, recordID: recordID)
        ck["kind"] = "host" as CKRecordValue
        ck["payload"] = Data("from the server".utf8) as CKRecordValue
        ck["modifiedAt"] = Date(timeIntervalSince1970: 10) as CKRecordValue
        return ck
    }

    @Test("A record remembered from a fetch is written on top of, not replaced")
    func fetchedRecordsBecomeTheBaseOfTheNextWrite() async {
        let outbox = CloudKitSyncTransport.Outbox()
        let fetched = serverRecord("alpha")

        // Nothing known yet: this is the state the second device was permanently stuck in.
        #expect(await outbox.serverCopy(of: fetched.recordID) == nil)

        await outbox.remember([fetched])
        let known = await outbox.serverCopy(of: fetched.recordID)
        #expect(known === fetched, "the fetched record itself is what carries the change tag")

        let mine = SyncRecord(kind: .host, id: "alpha", payload: Data("mine".utf8), modifiedAt: Date(timeIntervalSince1970: 20), deleted: false)
        let update = CloudKitSyncTransport.ckRecord(from: mine, id: fetched.recordID, basedOn: known)
        #expect(update === fetched, "an edit of a pulled record must build on the server's copy")
        #expect(update["payload"] as? Data == Data("mine".utf8))
    }

    @Test("A record deleted remotely is forgotten rather than kept as a base")
    func deletionsDropTheServerCopy() async {
        let outbox = CloudKitSyncTransport.Outbox()
        let fetched = serverRecord("beta")
        await outbox.remember([fetched])
        await outbox.forget([fetched.recordID])
        // Otherwise a later record with the same id would be written on top of a copy the
        // server no longer has, and refused for a reason nobody could see.
        #expect(await outbox.serverCopy(of: fetched.recordID) == nil)
    }
}
