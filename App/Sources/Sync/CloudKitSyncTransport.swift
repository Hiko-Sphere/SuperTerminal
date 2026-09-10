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
    /// What the server refused. Read by `push`, so a failure reaches the caller instead of
    /// being dropped (D-075).
    private let failures = Failures()

    init(container: CKContainer = CKContainer(identifier: CloudKitSyncTransport.containerIdentifier), stateDirectory: URL) {
        database = container.privateCloudDatabase
        zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
        stateURL = stateDirectory.appendingPathComponent("cloudkit-sync-state.json")
        delegate = Delegate(inbox: inbox, outbox: outbox, failures: failures, stateURL: stateURL, zoneID: zoneID)
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
                let known = await outbox.serverCopy(of: id)
                await outbox.put(Self.ckRecord(from: record, id: id, basedOn: known), for: id)
                changes.append(.saveRecord(id))
            }
        }
        engine.state.add(pendingRecordZoneChanges: changes)
        try await engine.sendChanges()
        let accepted = await inbox.drainAccepted()
        let refused = await failures.drain()

        // A push where the server refused everything used to return an empty list, which the
        // caller reads as "nothing to do" — the same answer as a clean sync with no changes.
        // That is how a feature that never worked once can look like one with nothing to say
        // (D-075). Transient failures are still the engine's business to retry; this is about
        // the ones it hands back.
        if !refused.records.isEmpty || !refused.zones.isEmpty {
            #if DEBUG
            for failure in refused.records { SyncDiagnostics.record(failure.error, doing: .recordSave, in: stateURL.deletingLastPathComponent()) }
            for failure in refused.zones { SyncDiagnostics.record(failure.error, doing: .zoneSave, in: stateURL.deletingLastPathComponent()) }
            #endif
            if accepted.isEmpty, let first = (refused.zones.first?.error ?? refused.records.first?.error) {
                throw first
            }
        }
        return accepted.compactMap { Self.syncKey(from: $0) }
    }

    func purgeAll() async throws {
        guard let engine else { return }
        // The cleanup and the zone's re-creation happen whether or not the send throws.
        // They used to sit after `sendChanges()` in a straight line, so a purge that failed
        // — the very case a purge is reached in — left the process with the zone deleted,
        // the outbox uncleared and nothing anywhere that would ever queue the zone again.
        // Every later push then failed on a missing zone, permanently and quietly.
        defer {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        }
        engine.state.add(pendingDatabaseChanges: [.deleteZone(zoneID)])
        do {
            try await engine.sendChanges()
        } catch {
            await outbox.removeAll()
            try? FileManager.default.removeItem(at: stateURL)
            throw error
        }
        await outbox.removeAll()
        try? FileManager.default.removeItem(at: stateURL)
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

    /// Builds the record to send.
    ///
    /// `basedOn` is the server's own copy when one is known, so that an update carries the
    /// change tag CloudKit uses to detect conflicts. Sending a freshly built `CKRecord` for a
    /// record the server already has is a write that says "this is new", and CloudKit refuses
    /// it with `serverRecordChanged` every time (D-075).
    static func ckRecord(from record: SyncRecord, id: CKRecord.ID, basedOn known: CKRecord? = nil) -> CKRecord {
        let ck = known ?? CKRecord(recordType: recordType, recordID: id)
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
        /// Queued to send. Taking one removes it: leaving it behind meant every record ever
        /// pushed stayed in memory for the life of the process, and a later batch could hand
        /// the engine a record it had already sent.
        private var pending: [CKRecord.ID: CKRecord] = [:]
        /// The server's own copy of each record, as it last came back — from a save that
        /// succeeded, from a fetch, or from the `serverRecord` on a conflict. This is what
        /// carries CloudKit's system fields, and above all the change tag (D-075).
        ///
        /// Without it every `CKRecord` is built fresh, which tells the server "I am writing
        /// this for the first time"; the second write of the same record is then refused with
        /// `serverRecordChanged`, for ever. Apple calls this the last-known-record pattern and
        /// `CKSyncEngineEvent.h` asks for it in as many words.
        private var lastKnown: [CKRecord.ID: CKRecord] = [:]

        func put(_ record: CKRecord, for id: CKRecord.ID) { pending[id] = record }
        func take(_ id: CKRecord.ID) -> CKRecord? { pending.removeValue(forKey: id) }
        func remember(_ records: [CKRecord]) {
            for record in records { lastKnown[record.recordID] = record }
        }
        func forget(_ ids: [CKRecord.ID]) {
            for id in ids { lastKnown[id] = nil }
        }
        func serverCopy(of id: CKRecord.ID) -> CKRecord? { lastKnown[id] }
        func removeAll() {
            pending.removeAll()
            lastKnown.removeAll()
        }
    }

    /// Everything the server refused, which used to be nothing because nobody looked (D-075).
    ///
    /// `CKSyncEngine` reports per-record and per-zone failures on its events, not on the error
    /// thrown by `sendChanges()`. A transport that reads only the success halves reports a
    /// push as clean whatever the server thought of it, and that is how a sync that never
    /// worked can look like a sync with nothing to do.
    actor Failures {
        private(set) var records: [(id: CKRecord.ID, error: Error)] = []
        private(set) var zones: [(id: CKRecordZone.ID, error: Error)] = []

        func record(id: CKRecord.ID, error: Error) { records.append((id, error)) }
        func record(zone: CKRecordZone.ID, error: Error) { zones.append((zone, error)) }

        /// Takes what has accumulated, so a caller reports each failure once.
        func drain() -> (records: [(id: CKRecord.ID, error: Error)], zones: [(id: CKRecordZone.ID, error: Error)]) {
            defer { records.removeAll(); zones.removeAll() }
            return (records, zones)
        }

        var isEmpty: Bool { records.isEmpty && zones.isEmpty }
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
        private let failures: Failures
        private let stateURL: URL
        /// Needed here, not only in the transport: an account change clears the engine's
        /// pending database changes, and this is where the zone has to be asked for again.
        private let zoneID: CKRecordZone.ID

        init(inbox: Inbox, outbox: Outbox, failures: Failures, stateURL: URL, zoneID: CKRecordZone.ID) {
            self.inbox = inbox
            self.outbox = outbox
            self.failures = failures
            self.stateURL = stateURL
            self.zoneID = zoneID
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
                // The server's copy of everything that just arrived, kept for the same reason
                // an accepted save is kept: the change tag. Without this the *second* device
                // has no server copy of a record it only ever pulled, so its first local edit
                // builds a fresh `CKRecord` that tells the server "this is new" — and is
                // refused with `serverRecordChanged` for ever. D-075 fixed that on the save
                // path and the doc comment on `lastKnown` claimed the fetch path too; the
                // fetch path was never wired, which is exactly the two-device case.
                await outbox.remember(changes.modifications.map(\.record))
                await outbox.forget(changes.deletions.map(\.recordID))
                await inbox.add(records)
            case let .sentRecordZoneChanges(sent):
                await inbox.addAccepted(sent.savedRecords.map(\.recordID) + sent.deletedRecordIDs)
                // The server's copy of everything it accepted, kept so the *next* write of
                // the same record carries its change tag (D-075).
                await outbox.remember(sent.savedRecords)
                await outbox.forget(sent.deletedRecordIDs)

                // And the halves that used to be dropped on the floor. `CKSyncEngine` does
                // not put per-record failures on the error thrown by `sendChanges()`; it
                // delivers them here. Reading only `savedRecords` meant a record that the
                // server refused was indistinguishable from one it never saw.
                for failure in sent.failedRecordSaves {
                    await failures.record(id: failure.record.recordID, error: failure.error)
                    // The zone is gone — deleted from another device, or removed with the
                    // account's iCloud data. Apple's own guidance is to put it back and send
                    // the record again; without that branch a send into a missing zone fails
                    // permanently and silently, and `SyncFailure` tells the user the zone "is
                    // recreated on the next sync" while nothing recreates it.
                    if failure.error.code == .zoneNotFound || failure.error.code == .userDeletedZone {
                        await outbox.put(failure.record, for: failure.record.recordID)
                        syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: failure.record.recordID.zoneID))])
                        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)])
                        continue
                    }
                    guard let serverRecord = failure.error.serverRecord else { continue }
                    // The documented resolution: take the server's record, put our fields
                    // back on it, and queue it again. Without this a conflict is permanent.
                    await outbox.remember([serverRecord])
                    if let mine = await outbox.serverCopy(of: failure.record.recordID) {
                        for key in ["kind", "payload", "modifiedAt"] {
                            mine[key] = failure.record[key]
                        }
                        await outbox.put(mine, for: mine.recordID)
                        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(mine.recordID)])
                    }
                }
                for failure in sent.failedRecordDeletes {
                    await failures.record(id: failure.key, error: failure.value)
                }
            case let .sentDatabaseChanges(sent):
                // A refused zone creation used to fall into `default:` and vanish. It is the
                // one failure that makes every record push fail afterwards, so it is the last
                // one that should be silent.
                for failure in sent.failedZoneSaves {
                    await failures.record(zone: failure.zone.zoneID, error: failure.error)
                }
                for failure in sent.failedZoneDeletes {
                    await failures.record(zone: failure.key, error: failure.value)
                }
            case let .accountChange(change):
                // Not a no-op, and the header says why: "When the logged-in account changes,
                // the sync engine resets its internal state. This means that it clears any
                // pending database or record zone changes that you may have added."
                //
                // The zone save is queued in `init` and at the tail of `purgeAll`, and
                // nowhere else — so a sign-in, a sign-out or a switch silently threw away the
                // only request this app would ever make to create its zone, and every push
                // afterwards failed on a zone that nothing would put back. The change tags
                // and the change tokens belong to the account that has just gone, too.
                await outbox.removeAll()
                try? FileManager.default.removeItem(at: stateURL)
                switch change.changeType {
                case .signIn, .switchAccounts:
                    syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
                case .signOut:
                    // Nothing to create for an account that is no longer there. The next
                    // sign-in queues it.
                    break
                @unknown default:
                    syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
                }
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
