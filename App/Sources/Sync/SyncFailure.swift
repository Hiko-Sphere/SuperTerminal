import CloudKit
import Foundation

/// Turns a CloudKit error into a sentence that says what to do about it (D-032).
///
/// The status line used to show `String(describing:)` of the error, which for a `CKError`
/// is `<CKError 0x…: "Not Authenticated" (9/1002)>`. That is a developer's string in a
/// place a user reads: it names a number rather than the thing they can fix, and the two
/// most common failures — not signed in, and no network — are the two most fixable.
///
/// Pure, so every case is tested without a CloudKit account.
enum SyncFailure {
    static func describe(_ error: Error) -> String {
        guard let ck = error as? CKError else {
            return (error as NSError).localizedDescription
        }
        // A partial failure's own message says nothing; the reason is in the item that
        // failed, and one reason is enough to act on.
        if ck.code == .partialFailure, let first = ck.partialErrorsByItemID?.values.first {
            return describe(first)
        }
        return sentence(for: ck)
    }

    /// CloudKit's own words for a rejection, when it gave any. The generic sentence above
    /// is true but unactionable — "record type SyncRecord not found" is the difference
    /// between a shrug and a fix — and this is the one branch nobody can act on without it.
    private static func serverDetail(_ ck: CKError) -> String {
        let candidates = [
            ck.userInfo["ServerErrorDescription"] as? String,
            (ck.userInfo[NSUnderlyingErrorKey] as? NSError)?.localizedDescription,
        ]
        guard let detail = candidates.compactMap({ $0 }).first(where: { !$0.isEmpty }) else { return "" }
        return " " + detail.prefix(200)
    }

    private static func sentence(for ck: CKError) -> String {
        switch ck.code {
        case .notAuthenticated:
            String(localized: "Sign in to iCloud in Settings, then try again.")
        case .accountTemporarilyUnavailable:
            String(localized: "iCloud is not available on this device right now. It usually returns on its own; try again in a few minutes.")
        case .managedAccountRestricted:
            String(localized: "This managed Apple Account is not allowed to use iCloud.")
        case .permissionFailure:
            String(localized: "iCloud Drive is turned off for this app. Turn it on in Settings → your name → iCloud.")
        case .networkUnavailable, .networkFailure:
            String(localized: "No network. Sync will resume when there is one.")
        case .serviceUnavailable, .requestRateLimited, .zoneBusy:
            String(localized: "iCloud is busy. This retries on its own.")
        case .quotaExceeded:
            String(localized: "Your iCloud storage is full, so nothing more can be saved to it.")
        case .zoneNotFound, .userDeletedZone:
            String(localized: "The app's iCloud data was removed. It is recreated on the next sync.")
        case .badContainer, .missingEntitlement:
            String(localized: "This build cannot reach iCloud: it is signed without the app's iCloud container. Install a build signed with the right team.")
        case .incompatibleVersion:
            String(localized: "This version is too old for the data in iCloud. Update the app.")
        case .changeTokenExpired:
            String(localized: "The app was out of touch with iCloud for too long. The next sync fetches everything again.")
        case .serverRecordChanged:
            String(localized: "Another device changed the same item. The newer change wins; try again.")
        case .limitExceeded:
            // Not "this retries in smaller pieces": `limitExceeded` also arrives for a
            // single record that is over CloudKit's own size limit, and no amount of
            // splitting makes one record smaller. Promising a retry that cannot work
            // leaves the app looping under a reassuring sentence.
            String(localized: "One change was too large for iCloud to accept. Smaller changes still sync.")
        case .constraintViolation, .serverRejectedRequest, .invalidArguments:
            // Nothing the user did, and nothing they can do; say so rather than blame
            // them — but carry the code, because this is the branch a developer has to
            // act on and three codes share the sentence.
            String(localized: "iCloud rejected the change (CloudKit \(ck.errorCode)). This is a fault in the app, not something you did.")
                + serverDetail(ck)
        default:
            // Everything else keeps the system's own wording, with the code so a
            // diagnostics export can be matched to Apple's documentation.
            String(localized: "\(ck.localizedDescription) (CloudKit \(ck.errorCode))")
        }
    }
}
