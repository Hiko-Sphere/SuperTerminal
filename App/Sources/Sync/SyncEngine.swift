import Foundation
import Observation

/// Reconciles the app's records with the copies in iCloud.
///
/// Last writer wins, by each record's own modification time, in both directions — with
/// one exception that is not negotiable. A known-host record from another device whose
/// key differs from the one this device already trusts is **never applied**. It is held as
/// a conflict and the ordinary host-key-changed prompt settles it with the user on the next
/// connection. Sync is a convenience; the host-key check is the security model, and a
/// convenience does not get to override it.
///
/// Deletions travel as tombstones so a device that deleted something while offline does not
/// have it handed straight back by the next device to sync.
@Observable
@MainActor
final class SyncEngine {
    enum Status: Equatable, Sendable {
        case idle
        case syncing
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var lastSynced: Date?
    /// Remote host keys that differ from a locally trusted one. Read by the connection
    /// path so the changed-key prompt can show what the other device had.
    private(set) var conflicts: [SyncKey: SyncConflict] = [:]

    private let transport: any SyncTransport
    private let local: any SyncLocalStore
    /// What has been pushed already, so an unchanged record is not sent every time.
    private var pushed: [SyncKey: Date] = [:]

    init(transport: any SyncTransport, local: any SyncLocalStore) {
        self.transport = transport
        self.local = local
    }

    /// One full reconciliation: pull, merge, push.
    func sync() async {
        guard status != .syncing else { return }
        status = .syncing
        do {
            let remote = try await transport.pullChanges()
            try await merge(remote)
            let outgoing = await pendingLocalChanges()
            let accepted = try await transport.push(outgoing)
            // Remember the modification time that was sent, not the time of sending. The
            // first version compared a record's modifiedAt against the wall clock at push
            // and so never re-sent anything stamped earlier than its last push — every edit
            // made within the same second, and every record from a device whose clock ran
            // behind. A test caught it on the third sync.
            let sentAt = Dictionary(uniqueKeysWithValues: outgoing.map { ($0.key, $0.modifiedAt) })
            for key in accepted { pushed[key] = sentAt[key] }
            lastSynced = Date()
            status = .idle
        } catch {
            status = .failed(String(describing: error))
        }
    }

    /// Removes everything this app stored remotely. Called by "Delete all data": leaving
    /// a copy in iCloud after promising to delete everything would make the promise false.
    func purgeRemote() async throws {
        try await transport.purgeAll()
        pushed.removeAll()
        conflicts.removeAll()
        lastSynced = nil
    }

    /// The user answered the changed-key prompt; the held record is no longer needed.
    func resolveConflict(_ key: SyncKey) {
        conflicts[key] = nil
    }

    /// Takes the other device's key for this host. Applied, then marked as pushed so it
    /// is not echoed back.
    func acceptConflict(_ key: SyncKey) async throws {
        guard let conflict = conflicts[key] else { return }
        try await local.apply(conflict.remote)
        pushed[key] = conflict.remote.modifiedAt
        conflicts[key] = nil
    }

    /// Keeps this device's key and sends it up on the next sync, so the other device
    /// is asked the same question rather than left disagreeing silently.
    func keepLocal(_ key: SyncKey) {
        conflicts[key] = nil
        pushed[key] = nil
    }

    // MARK: - Reconciliation

    private func merge(_ remote: [SyncRecord]) async throws {
        let mine = Dictionary(uniqueKeysWithValues: (await local.localRecords()).map { ($0.key, $0) })
        for record in remote {
            if let existing = mine[record.key], existing.modifiedAt >= record.modifiedAt {
                // Ours is at least as new. Last writer wins, and that is us.
                continue
            }
            if record.kind == .knownHost, !record.deleted,
               let trusted = await local.trustedHostKeyPayload(for: record.id),
               trusted != record.payload
            {
                // A different key for a host we already trust. Held, not applied.
                conflicts[record.key] = SyncConflict(key: record.key, reason: .hostKeyDiffers, remote: record)
                continue
            }
            try await local.apply(record)
            // Applying a remote record must not cause it to be pushed straight back.
            pushed[record.key] = record.modifiedAt
        }
    }

    private func pendingLocalChanges() async -> [SyncRecord] {
        await local.localRecords().filter { record in
            guard let sent = pushed[record.key] else { return true }
            return record.modifiedAt != sent
        }
    }
}
