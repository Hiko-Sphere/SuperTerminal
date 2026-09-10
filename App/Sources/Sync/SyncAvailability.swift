import Foundation

/// Whether iCloud sync is offered at all (D-037, corrected by D-081).
///
/// The engine, the merge, the tombstones and the CloudKit mapping are all written and tested.
/// What was recorded here for months was that the *container* was at fault — every push
/// refused with `CKErrorDomain 15` and HTTP 500, fixable only in the CloudKit Console. That
/// account does not survive being checked, and three separate things are wrong with it.
///
/// **The build was pointed at the wrong database.** `com.apple.developer.icloud-container-environment`
/// in the signed product reads `Production`, on a build whose `get-task-allow` is `true` and
/// whose `aps-environment` is `development`. It comes from `ST_ICLOUD_ENVIRONMENT = Production`
/// in the Release configuration, and `-configuration Release` is the only way onto a device the
/// project has ever documented. Production does not create record types on first write the way
/// Development does, and the schema has never been deployed there — so every push from every
/// device build was refused for a reason that lives in this repository. `CloudKitEnvironment`
/// now reads that value back out of the built product and the app says it out loud.
///
/// **The measurement was taken against a different container.** When the diagnosis was
/// written the code named `iCloud.dev.superterminal.app` and zone `SuperTerminal`. The rename
/// commit changed both — and rewrote the recorded device dump's `ContainerID` line from
/// `superterminal` to `apexterminal` in the same commit. That edited line was later cited as
/// proof the failure had been observed against the current container. It had not been. Nothing
/// has ever pushed to `iCloud.dev.apexterminal.app`.
///
/// **And the instrument could not see the answer either way.** `pullChanges` returns whatever
/// the inbox drained; a fetch against a database with no zone succeeds and yields nothing,
/// which is indistinguishable from a healthy empty pull. So "pulling works, therefore the
/// account and the entitlements are fine" was never a measurement. At the time of the dump the
/// delegate read only the success halves of `.sentRecordZoneChanges` and let
/// `.sentDatabaseChanges` — where a refused *zone creation* is reported — fall into `default:`.
/// A refused zone creation is exactly the failure that makes every later push fail while pulls
/// keep looking healthy.
///
/// Four client defects that would each have broken sync on their own were found underneath and
/// fixed in D-081: no `zoneNotFound` recovery at all; `.accountChange` handled as a no-op even
/// though the engine clears the pending zone save on it; `purgeAll` restoring the zone only on
/// the path where the send succeeded; and the change tag never remembered from a *fetch*, so
/// the second device's first edit of a pulled record was refused for ever. D-075 fixed the
/// change tag on the save path and its own comment claimed the fetch path too; the fetch path
/// was not wired.
///
/// **The switch is now offered, by the owner's decision, and this is exactly what that means.**
/// The client defects are fixed and the path is under test, but no push has ever been made to
/// this container from a build with the right environment — so the first person to turn it on
/// is taking the first real measurement. That is a reasonable thing to do deliberately and a
/// bad thing to do by accident, so the app is built to make it legible rather than to pretend:
///
/// * Settings → iCloud states which CloudKit database the build talks to, and warns when that
///   is **Production**, where a record type nobody deployed is refused outright.
/// * A refused push now throws instead of returning the same empty list as a clean one, so the
///   status line says "Last sync failed" with CloudKit's own reason rather than nothing.
/// * `sync-failure.log` appends and labels each entry with the operation, so the next
///   diagnosis cannot repeat the last one's mistake of reading a fetch failure as a push.
///
/// What is still true and worth keeping in view: **nothing here is a promise that a copy exists
/// elsewhere.** Until two devices have been seen to sync, the only copy of a connection is on
/// the device that made it. `docs/HUMAN_ACTIONS.md` H-5 has the steps for establishing that,
/// in the corrected order — a Debug build first, the Console last.
enum SyncAvailability {
    /// Offered. See the note above for what has and has not been verified.
    static let isAvailable = true

    /// Why it is not offered, for the one place that says so.
    static var unavailableReason: String {
        String(localized: "Syncing is not available in this version. Everything stays on this device, which is where it already was — nothing you have saved is affected.")
    }
}
