import Foundation

/// Whether iCloud sync is offered at all (D-037).
///
/// The engine, the merge, the tombstones and the CloudKit mapping are all written and
/// tested. What is not working is the container: every push is refused by the server with
/// `CKErrorDomain 15` and HTTP 500 — and an HTTP 500 is a *request*-level status, so the
/// request never reached record validation at all (CloudKit reports per-record validation
/// failures as a partial failure on an otherwise successful response). Pulling works, so the
/// account and the entitlements are fine; the container's own state is not, and that is fixed
/// in the CloudKit Console rather than in code. `docs/HUMAN_ACTIONS.md` H-5 has the steps.
///
/// **Two client-side defects were found underneath that and fixed (D-075), and neither of
/// them was the cause.** They are recorded here because both were invisible and both would
/// have bitten the moment the container was fixed:
///
/// * Every `CKRecord` was built fresh, so no write ever carried CloudKit's change tag. The
///   *first* write of a record would have worked and every write after it would have been
///   refused with `serverRecordChanged`, for ever.
/// * `CKSyncEngine` delivers per-record and per-zone failures on its events, not on the error
///   thrown by `sendChanges()`. The transport read only the success halves, so a push the
///   server refused returned the same empty list as a push with nothing to send.
///
/// That second one matters for how much the sentence above is worth: a refused push was
/// reported as a clean one, so "pulling works and pushing does not" was measured with an
/// instrument that could not see a per-record refusal. The HTTP 500 was read off a real
/// device (D-036) and stands on its own — it is a request-level status, not a per-record one —
/// but anything finer-grained than that will have to be measured again now that the transport
/// actually reports what it is told.
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
