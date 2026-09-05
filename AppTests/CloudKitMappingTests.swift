import CloudKit
import Foundation
import Testing
@testable import SuperTerminal

/// The one part of the CloudKit transport that can be proved without an iCloud account:
/// that a record survives the round trip through `CKRecord` intact, and that identities
/// cannot collide across kinds. Everything past this needs signing (B-4).
@Suite("CloudKit record mapping")
struct CloudKitMappingTests {
    private let zone = CKRecordZone.ID(zoneName: "SuperTerminal", ownerName: CKCurrentUserDefaultName)

    @Test("A record round-trips through CKRecord unchanged")
    func roundTrip() {
        let original = SyncRecord(kind: .snippet, id: "s-1", payload: Data("df -h".utf8),
                                  modifiedAt: Date(timeIntervalSince1970: 1_700_000_000), deleted: false)
        let id = CloudKitSyncTransport.recordID(for: original.key, zoneID: zone)
        let ck = CloudKitSyncTransport.ckRecord(from: original, id: id)
        #expect(CloudKitSyncTransport.syncRecord(from: ck) == original)
    }

    @Test("The same id under two kinds is two records")
    func kindsDoNotCollide() {
        // A host and a snippet that happen to share a UUID must not overwrite each other.
        let a = CloudKitSyncTransport.recordID(for: SyncKey(kind: .host, id: "X"), zoneID: zone)
        let b = CloudKitSyncTransport.recordID(for: SyncKey(kind: .snippet, id: "X"), zoneID: zone)
        #expect(a != b)
        #expect(CloudKitSyncTransport.syncKey(from: a) == SyncKey(kind: .host, id: "X"))
        #expect(CloudKitSyncTransport.syncKey(from: b) == SyncKey(kind: .snippet, id: "X"))
    }

    @Test("An id containing the separator still parses")
    func separatorInsideID() {
        // Known-host ids are "host:port" and can carry anything; the split is bounded.
        let key = SyncKey(kind: .knownHost, id: "a|b|c:22")
        let id = CloudKitSyncTransport.recordID(for: key, zoneID: zone)
        #expect(CloudKitSyncTransport.syncKey(from: id) == key)
    }

    @Test("A record of an unknown kind is ignored rather than trusted")
    func unknownKindIsIgnored() {
        let id = CKRecord.ID(recordName: "future-kind|whatever", zoneID: zone)
        #expect(CloudKitSyncTransport.syncKey(from: id) == nil)
        let ck = CKRecord(recordType: CloudKitSyncTransport.recordType, recordID: id)
        ck["payload"] = Data() as CKRecordValue
        ck["modifiedAt"] = Date() as CKRecordValue
        #expect(CloudKitSyncTransport.syncRecord(from: ck) == nil)
    }

    @Test("A record missing its fields is ignored")
    func missingFieldsAreIgnored() {
        let id = CloudKitSyncTransport.recordID(for: SyncKey(kind: .host, id: "h"), zoneID: zone)
        let ck = CKRecord(recordType: CloudKitSyncTransport.recordType, recordID: id)
        #expect(CloudKitSyncTransport.syncRecord(from: ck) == nil)
    }
}
