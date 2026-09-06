import Foundation

/// What can be synchronised, and how each kind is reconciled.
///
/// Deliberately a closed list. Command history and the list of recently open sessions are
/// not here on purpose (D-012, T-11): both are records of what a person *did*, and the
/// promise that they never leave the device is the reason the app is allowed to keep them
/// at all. Diagnostics are not here either.
enum SyncKind: String, Codable, CaseIterable, Sendable {
    case host
    case keyMetadata
    case snippet
    case knownHost
    /// A saved remote screen (D-027). A device still on an older version drops records of
    /// a kind it does not know, which is exactly the right behaviour here.
    case screen
}

/// One synchronised record, as the engine sees it: an opaque payload plus what it needs
/// to reconcile — identity, a modification time, and whether it has been deleted.
///
/// Deletions are tombstones rather than absences. Without them, a device that deleted a
/// host while offline would receive it straight back from the next device to sync.
struct SyncRecord: Codable, Equatable, Sendable {
    var kind: SyncKind
    var id: String
    var payload: Data
    var modifiedAt: Date
    var deleted: Bool

    var key: SyncKey { SyncKey(kind: kind, id: id) }
}

struct SyncKey: Hashable, Codable, Sendable {
    var kind: SyncKind
    var id: String
}

/// A change the engine would not apply on its own.
///
/// The only kind that exists is the one that matters most: another device presenting a
/// *different* key for a host this device already trusts. That is exactly the situation
/// the host-key check exists to catch, and having it arrive through iCloud instead of
/// through the network changes nothing about how seriously it must be taken. The record
/// is held and the existing "host key changed" prompt decides, with the user, on the next
/// connection — a synced key is never trusted silently.
struct SyncConflict: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        case hostKeyDiffers
    }
    var key: SyncKey
    var reason: Reason
    var remote: SyncRecord
}

/// Where records go and come from. `CloudKitSyncTransport` implements it over CloudKit;
/// tests implement it in memory.
///
/// A protocol so that the reconciliation logic — where the mistakes would live — can be
/// tested exhaustively without an iCloud account. That does not make the transport
/// verified; it makes the engine verified. The distinction is recorded in TEST_REPORT.
protocol SyncTransport: Sendable {
    /// Records changed remotely since the last call. Empty when nothing changed.
    func pullChanges() async throws -> [SyncRecord]
    /// Sends local changes. Returns the keys that were accepted.
    func push(_ records: [SyncRecord]) async throws -> [SyncKey]
    /// Removes every record this app has stored remotely.
    func purgeAll() async throws
}

/// What the engine needs from the app's own stores, in one place.
///
/// The engine does not know what a host or a snippet is; it moves opaque payloads and
/// asks the app to apply them. The app decides how a payload becomes a `Host`, which
/// keeps every model's own validation in force on data that arrived from another device.
protocol SyncLocalStore: AnyObject, Sendable {
    /// Every current local record, including tombstones the app still remembers.
    func localRecords() async -> [SyncRecord]
    /// Applies a remote record — inserting, updating, or removing on a tombstone.
    func apply(_ record: SyncRecord) async throws
    /// For a known-host record only: the key this device currently trusts for the same
    /// identity, if any, so the engine can refuse to overwrite it.
    func trustedHostKeyPayload(for id: String) async -> Data?
}
