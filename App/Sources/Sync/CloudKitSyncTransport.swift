import CloudKit
import Foundation

/// `SyncTransport` over CloudKit's private database, driven by `CKSyncEngine`.
///
/// `CKSyncEngine` owns the hard parts — change tokens, retry, backoff, account changes,
/// and the record-zone bookkeeping that hand-rolled CloudKit code gets wrong — and hands
/// this type events. What this type contributes is the mapping between the engine's
/// opaque `SyncRecord` and a `CKRecord`, one custom zone, and a purge that deletes the
/// zone rather than walking records.
///
/// **Not live-verified.** The entitlement is declared, but an ad-hoc simulator build has
/// it stripped and a device build needs a team (B-4). The mapping is unit-tested offline,
/// since `CKRecord` can be built without a container; everything past that is written
/// against the SDK's own interface and awaits signing. TEST_REPORT states this; nothing
/// here claims otherwise.
final class CloudKitSyncTransport: SyncTransport, @unchecked Sendable {
    static let containerIdentifier = "iCloud.dev.apexterminal.app"
    static let zoneName = "ApexTerminal"
    static let recordType = "SyncRecord"

    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID
    private let stateURL: URL
    private var engine: CKSyncEngine?
    private let delegate: Delegate

    /// Records fetched by the engine since the last `pullChanges`.
    private let inbox = Inbox()
    /// Records handed to `push` and not yet confirmed sent. An actor, because the engine
    /// asks for them from whatever executor it is on; a plain dictionary read there would
    /// be a data race, and Swift 6 refuses to compile it rather than let it happen.
    private let outbox = Outbox()

    init(container: CKContainer = CKContainer(identifier: CloudKitSyncTransport.containerIdentifier), stateDirectory: URL) {
        database = container.privateCloudDatabase
        zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
        stateURL = stateDirectory.appendingPathComponent("cloudkit-sync-state.json")
        delegate = Delegate(inbox: inbox, outbox: outbox, stateURL: stateURL)
        var configuration = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: Self.loadState(from: stateURL),
            delegate: delegate
        )
        configuration.automaticallySync = true
        let engine = CKSyncEngine(configuration)
        self.engine = engine
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
    }

    // MARK: SyncTransport

    func pullChanges() async throws -> [SyncRecord] {
        guard let engine else { return [] }
        try await engine.fetchChanges()
        return await inbox.drain()
    }

    func push(_ records: [SyncRecord]) async throws -> [SyncKey] {
        guard let engine, !records.isEmpty else { return [] }
        var changes: [CKSyncEngine.PendingRecordZoneChange] = []
        for record in records {
            let id = Self.recordID(for: record.key, zoneID: zoneID)
            if record.deleted {
                changes.append(.deleteRecord(id))
            } else {
                await outbox.put(Self.ckRecord(from: record, id: id), for: id)
                changes.append(.saveRecord(id))
            }
        }
        engine.state.add(pendingRecordZoneChanges: changes)
        try await engine.sendChanges()
        // Whatever the engine reported as saved or deleted is accepted; failures stay
        // pending in the engine's own state and are retried by it.
        let accepted = await inbox.drainAccepted()
        return accepted.compactMap { Self.syncKey(from: $0) }
    }

    func purgeAll() async throws {
        guard let engine else { return }
        engine.state.add(pendingDatabaseChanges: [.deleteZone(zoneID)])
        try await engine.sendChanges()
        await outbox.removeAll()
        try? FileManager.default.removeItem(at: stateURL)
        // The zone is recreated lazily on the next push, so a purge followed by re-enabling
        // sync starts clean rather than failing on a missing zone.
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
    }

    // MARK: Mapping (unit-tested)

    /// Characters a record name may carry as themselves. Everything else is
    /// percent-encoded (D-034).
    ///
    /// CloudKit requires a record name to be ASCII, and the ids reaching here are not:
    /// a known host is identified by `host:port`, and by `host:port→jump` when it is
    /// behind a bastion — and `→` is U+2192. A name the server refuses fails the whole
    /// batch, which is every record, which is all of sync.
    ///
    /// `.` is deliberately *not* allowed through: it separates the kind from the id, and
    /// a hostname is full of them. Encoding it keeps the separator unambiguous.
    private static let nameSafe = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_~"
    )

    static func recordID(for key: SyncKey, zoneID: CKRecordZone.ID) -> CKRecord.ID {
        // The kind is a Swift identifier, so it needs no encoding and contains no "."
        let encoded = key.id.addingPercentEncoding(withAllowedCharacters: nameSafe) ?? key.id
        return CKRecord.ID(recordName: "\(key.kind.rawValue).\(encoded)", zoneID: zoneID)
    }

    static func syncKey(from id: CKRecord.ID) -> SyncKey? {
        let name = id.recordName
        if let dot = name.firstIndex(of: "."),
           let kind = SyncKind(rawValue: String(name[..<dot])) {
            let encoded = String(name[name.index(after: dot)...])
            return SyncKey(kind: kind, id: encoded.removingPercentEncoding ?? encoded)
        }
        // Records written before the names were encoded. Nothing shipped with them, but a
        // device that pushed some before updating should still be able to read them back.
        let parts = name.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let kind = SyncKind(rawValue: parts[0]) else { return nil }
        return SyncKey(kind: kind, id: parts[1])
    }

    static func ckRecord(from record: SyncRecord, id: CKRecord.ID) -> CKRecord {
        let ck = CKRecord(recordType: recordType, recordID: id)
        ck["kind"] = record.kind.rawValue as CKRecordValue
        ck["payload"] = record.payload as CKRecordValue
        ck["modifiedAt"] = record.modifiedAt as CKRecordValue
        return ck
    }

    static func syncRecord(from ck: CKRecord) -> SyncRecord? {
        guard let key = syncKey(from: ck.recordID),
              let payload = ck["payload"] as? Data,
              let modifiedAt = ck["modifiedAt"] as? Date
        else { return nil }
        return SyncRecord(kind: key.kind, id: key.id, payload: payload, modifiedAt: modifiedAt, deleted: false)
    }

    // MARK: State

    private static func loadState(from url: URL) -> CKSyncEngine.State.Serialization? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    actor Outbox {
        private var records: [CKRecord.ID: CKRecord] = [:]
        func put(_ record: CKRecord, for id: CKRecord.ID) { records[id] = record }
        func take(_ id: CKRecord.ID) -> CKRecord? { records[id] }
        func removeAll() { records.removeAll() }
    }

    /// What the engine fetched and what it confirmed, collected off the delegate.
    actor Inbox {
        private var fetched: [SyncRecord] = []
        private var accepted: [CKRecord.ID] = []
        func add(_ records: [SyncRecord]) { fetched.append(contentsOf: records) }
        func addAccepted(_ ids: [CKRecord.ID]) { accepted.append(contentsOf: ids) }
        func drain() -> [SyncRecord] { defer { fetched.removeAll() }; return fetched }
        func drainAccepted() -> [CKRecord.ID] { defer { accepted.removeAll() }; return accepted }
    }

    final class Delegate: CKSyncEngineDelegate, Sendable {
        private let inbox: Inbox
        private let outbox: Outbox
        private let stateURL: URL

        init(inbox: Inbox, outbox: Outbox, stateURL: URL) {
            self.inbox = inbox
            self.outbox = outbox
            self.stateURL = stateURL
        }

        func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
            switch event {
            case let .stateUpdate(update):
                // Persisted so the next launch resumes from the same change token rather
                // than re-fetching everything.
                if let data = try? JSONEncoder().encode(update.stateSerialization) {
                    try? data.write(to: stateURL, options: .atomicAndProtected)
                }
            case let .fetchedRecordZoneChanges(changes):
                var records: [SyncRecord] = []
                for modification in changes.modifications {
                    if let record = CloudKitSyncTransport.syncRecord(from: modification.record) { records.append(record) }
                }
                for deletion in changes.deletions {
                    if let key = CloudKitSyncTransport.syncKey(from: deletion.recordID) {
                        records.append(SyncRecord(kind: key.kind, id: key.id, payload: Data(), modifiedAt: Date(), deleted: true))
                    }
                }
                await inbox.add(records)
            case let .sentRecordZoneChanges(sent):
                await inbox.addAccepted(sent.savedRecords.map(\.recordID) + sent.deletedRecordIDs)
            case .accountChange:
                // Sign-out or a switched account: the engine drops its state itself; the
                // app's own toggle decides whether to keep syncing. Nothing to do here.
                break
            default:
                break
            }
        }

        func nextRecordZoneChangeBatch(
            _ context: CKSyncEngine.SendChangesContext,
            syncEngine: CKSyncEngine
        ) async -> CKSyncEngine.RecordZoneChangeBatch? {
            let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
            let outbox = self.outbox
            return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { id in
                await outbox.take(id)
            }
        }
    }
}
