import CloudKit
import Foundation
import Testing
@testable import SuperTerminal

/// What a failed sync tells the user (D-032).
///
/// The status line is the only place a sync failure is ever explained, so every code that
/// a user can actually do something about must produce the thing to do — not a number.
@Suite struct SyncFailureTests {
    private func error(_ code: CKError.Code, userInfo: [String: Any] = [:]) -> CKError {
        CKError(_nsError: NSError(domain: CKErrorDomain, code: code.rawValue, userInfo: userInfo))
    }

    @Test("The failures a user can fix say what to do")
    func actionable() {
        #expect(SyncFailure.describe(error(.notAuthenticated)).contains("Sign in to iCloud"))
        #expect(SyncFailure.describe(error(.quotaExceeded)).contains("storage is full"))
        #expect(SyncFailure.describe(error(.permissionFailure)).contains("iCloud Drive"))
        #expect(SyncFailure.describe(error(.incompatibleVersion)).contains("Update the app"))
        // None of them shows the reader a raw error code or an object address.
        for code in [CKError.Code.notAuthenticated, .quotaExceeded, .permissionFailure, .incompatibleVersion] {
            let text = SyncFailure.describe(error(code))
            #expect(!text.contains("CKError"), "\(code) leaked the type name")
            #expect(!text.contains("0x"), "\(code) leaked a pointer")
        }
    }

    @Test("The failures that fix themselves say so, so nobody goes looking")
    func transient() {
        #expect(SyncFailure.describe(error(.networkUnavailable)).contains("No network"))
        #expect(SyncFailure.describe(error(.serviceUnavailable)).contains("retries on its own"))
        #expect(SyncFailure.describe(error(.zoneNotFound)).contains("recreated"))
        #expect(SyncFailure.describe(error(.changeTokenExpired)).contains("fetches everything again"))
    }

    @Test("A build that cannot reach iCloud at all is named as a build problem")
    func configuration() {
        // The one class of failure the user cannot fix on the device, and the one most
        // easily mistaken for "iCloud is broken".
        for code in [CKError.Code.badContainer, .missingEntitlement] {
            #expect(SyncFailure.describe(error(code)).contains("signed without the app's iCloud container"))
        }
    }

    @Test("A partial failure reports the item's reason, not its own")
    func partialFailure() {
        // CloudKit's own message for a partial failure says only that something failed.
        let inner = error(.quotaExceeded)
        let id = CKRecord.ID(recordName: "host|A", zoneID: CKRecordZone.ID(zoneName: "SuperTerminal", ownerName: CKCurrentUserDefaultName))
        let partial = error(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [id: inner]])
        #expect(SyncFailure.describe(partial) == SyncFailure.describe(inner))
    }

    @Test("A rejection carries CloudKit's own words when it gave any")
    func serverDetail() {
        // The generic sentence is true but unactionable; the server's reason is the
        // difference between a shrug and a fix.
        let withDetail = error(.serverRejectedRequest, userInfo: [
            "ServerErrorDescription": "record type SyncRecord not found in production schema",
        ])
        let text = SyncFailure.describe(withDetail)
        #expect(text.contains("CloudKit 15"), "the code is there: \(text)")
        #expect(text.contains("record type SyncRecord not found"), "and so is the reason: \(text)")

        // With nothing from the server it stays the plain sentence, not a dangling space.
        let bare = SyncFailure.describe(error(.serverRejectedRequest))
        #expect(!bare.hasSuffix(" "), "no trailing space when the server said nothing")
        #expect(bare.contains("CloudKit 15"))
    }

    @Test("Anything unrecognised keeps the system's wording and carries its code")
    func fallback() {
        let text = SyncFailure.describe(error(.internalError))
        #expect(text.contains("CloudKit \(CKError.Code.internalError.rawValue)"), "the code is there to look up: \(text)")
    }

    @Test("An error that is not CloudKit's is still readable")
    func notCloudKit() {
        let other = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [NSLocalizedDescriptionKey: "The request timed out."])
        #expect(SyncFailure.describe(other) == "The request timed out.")
    }
}
