import CloudKit
import Foundation
import Testing

@testable import ApexTerminal

/// What the transport does with the server's own copy of a record (D-075).
///
/// These are offline: `CKRecord` can be built without a container, which is the only reason
/// any of the CloudKit mapping is testable at all here. What they pin is the defect that
/// would have made sync fail on the *second* write of every record, silently, for as long as
/// the feature stayed switched off and nobody could see it.
@Suite("CloudKit conflict handling")
struct CloudKitConflictTests {
    private let zoneID = CKRecordZone.ID(zoneName: "ApexTerminal", ownerName: CKCurrentUserDefaultName)

    private func record(_ id: String, payload: String) -> SyncRecord {
        SyncRecord(
            kind: .host,
            id: id,
            payload: Data(payload.utf8),
            modifiedAt: Date(timeIntervalSince1970: 1_000_000),
            deleted: false
        )
    }

    @Test("An update is written on top of the server's copy, not as a new record")
    func updatesCarryTheServersRecord() {
        let id = CloudKitSyncTransport.recordID(for: SyncKey(kind: .host, id: "alpha"), zoneID: zoneID)

        // What the server gave back last time. In a real reply this also carries the change
        // tag, which is exactly what cannot be reconstructed by building a fresh record.
        let fromServer = CKRecord(recordType: CloudKitSyncTransport.recordType, recordID: id)
        fromServer["kind"] = "host" as CKRecordValue
        fromServer["payload"] = Data("old".utf8) as CKRecordValue
        fromServer["modifiedAt"] = Date(timeIntervalSince1970: 1) as CKRecordValue

        let update = CloudKitSyncTransport.ckRecord(from: record("alpha", payload: "new"), id: id, basedOn: fromServer)

        // The same object, with the fields replaced: identity is what carries the tag.
        #expect(update === fromServer)
        #expect(update["payload"] as? Data == Data("new".utf8))
        #expect(update["modifiedAt"] as? Date == Date(timeIntervalSince1970: 1_000_000))
        #expect(update.recordID == id)
    }

    @Test("A record the server has never seen is built fresh")
    func firstWriteIsANewRecord() {
        let id = CloudKitSyncTransport.recordID(for: SyncKey(kind: .host, id: "beta"), zoneID: zoneID)
        let first = CloudKitSyncTransport.ckRecord(from: record("beta", payload: "hello"), id: id, basedOn: nil)
        #expect(first.recordID == id)
        #expect(first.recordType == CloudKitSyncTransport.recordType)
        #expect(first["payload"] as? Data == Data("hello".utf8))
    }

    @Test("Taking a queued record removes it")
    func takingRemoves() async {
        let outbox = CloudKitSyncTransport.Outbox()
        let id = CloudKitSyncTransport.recordID(for: SyncKey(kind: .snippet, id: "one"), zoneID: zoneID)
        let queued = CKRecord(recordType: CloudKitSyncTransport.recordType, recordID: id)
        await outbox.put(queued, for: id)

        #expect(await outbox.take(id) === queued)
        // Second time: gone. It used to stay for ever, so every record ever pushed was held
        // for the life of the process and a later batch could hand the engine a stale one.
        #expect(await outbox.take(id) == nil)
    }

    @Test("The server's copy is remembered when it accepts, and forgotten when it deletes")
    func rememberingTheServersCopy() async {
        let outbox = CloudKitSyncTransport.Outbox()
        let id = CloudKitSyncTransport.recordID(for: SyncKey(kind: .knownHost, id: "gamma"), zoneID: zoneID)
        let saved = CKRecord(recordType: CloudKitSyncTransport.recordType, recordID: id)

        await outbox.remember([saved])
        #expect(await outbox.serverCopy(of: id) === saved)

        await outbox.forget([id])
        #expect(await outbox.serverCopy(of: id) == nil)
    }

    @Test("Failures are collected and handed over once")
    func failuresAreDrained() async {
        let failures = CloudKitSyncTransport.Failures()
        #expect(await failures.isEmpty)

        let id = CloudKitSyncTransport.recordID(for: SyncKey(kind: .host, id: "delta"), zoneID: zoneID)
        await failures.record(id: id, error: CKError(.serverRecordChanged))
        await failures.record(zone: zoneID, error: CKError(.zoneNotFound))

        let drained = await failures.drain()
        #expect(drained.records.count == 1)
        #expect(drained.zones.count == 1)
        // Once: a caller that reports each failure must not report it again on the next push.
        #expect(await failures.isEmpty)
    }
}
