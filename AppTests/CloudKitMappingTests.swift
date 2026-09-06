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

    /// CloudKit refuses a record name that is not ASCII, and refusing one fails the whole
    /// batch — which is every record, which is all of sync (D-034).
    @Test("A record name is ASCII and safe whatever the id carries, and still round-trips")
    func recordNamesAreSafe() throws {
        let zone = CKRecordZone.ID(zoneName: "SuperTerminal", ownerName: CKCurrentUserDefaultName)
        let awkward = [
            // A known host behind a bastion: the separator really is U+2192.
            SyncKey(kind: .knownHost, id: "build.example.com:443→internal.host:22"),
            SyncKey(kind: .knownHost, id: "[2001:db8::1]:22"),
            SyncKey(kind: .host, id: "8B2B7B4E-2C63-4E5E-9F52-2E9B5A9E4B10"),
            SyncKey(kind: .snippet, id: "a name with spaces, punctuation & 中文"),
            SyncKey(kind: .screen, id: "percent%already|pipe.dot"),
        ]
        let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_~%.")
        for key in awkward {
            let name = CloudKitSyncTransport.recordID(for: key, zoneID: zone).recordName
            let isASCII = name.unicodeScalars.allSatisfy { $0.isASCII }
            let isSafe = name.unicodeScalars.allSatisfy { safe.contains($0) }
            #expect(isASCII, "\(key.id) produced a non-ASCII name: \(name)")
            #expect(isSafe, "\(name) has a character CloudKit may refuse")
            #expect(!name.hasPrefix("_"), "a record name may not begin with an underscore")
            #expect(name.count <= 255)
            // And the id survives the trip, which is what deletions are matched on.
            #expect(CloudKitSyncTransport.syncKey(from: CKRecord.ID(recordName: name, zoneID: zone)) == key)
        }
    }

    @Test("Names written before they were encoded are still readable")
    func legacyRecordNames() {
        let zone = CKRecordZone.ID(zoneName: "SuperTerminal", ownerName: CKCurrentUserDefaultName)
        let legacy = CKRecord.ID(recordName: "knownHost|build.example.com:22", zoneID: zone)
        #expect(CloudKitSyncTransport.syncKey(from: legacy) == SyncKey(kind: .knownHost, id: "build.example.com:22"))
    }
}
