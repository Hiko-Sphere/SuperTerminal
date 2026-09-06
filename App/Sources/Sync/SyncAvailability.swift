import Foundation

/// Whether iCloud sync is offered at all (D-037).
///
/// The engine, the merge, the tombstones and the CloudKit mapping are all written and
/// tested. What is not working is the container: every push is refused by the server with
/// `CKErrorDomain 15` and HTTP 500, no server description and no per-record errors — the
/// request never reaches record validation. Pulling works, so the account and the
/// entitlements are fine; the container's own state is not, and that is fixed in the
/// CloudKit Console rather than in code.
///
/// So the switch is not offered. Shipping a toggle that always fails is worse than not
/// shipping the feature: it invites people to trust that their keys and connections are
/// safe somewhere else, which they are not.
///
/// To re-enable: set this to `true`. Nothing else is stubbed or removed — the whole path
/// is still compiled and still under test, and `SyncEngineTests` still run it against an
/// in-memory transport.
enum SyncAvailability {
    static let isAvailable = false

    /// Why it is not offered, for the one place that says so.
    static var unavailableReason: String {
        String(localized: "Syncing is not available in this version. Everything stays on this device, which is where it already was — nothing you have saved is affected.")
    }
}
