import Foundation
import STCore

/// The activity a session publishes so another device can pick it up (D-061).
///
/// Handoff cannot move an SSH session: the connection, its keys and its shell live on this
/// device, and the far end knows nothing about the handover. What it can carry is *which
/// server* — so continuing on an iPad opens a new session to the same connection, which is
/// what a person means by "carry on over there", and the app says as much rather than
/// implying the shell travelled.
enum SessionActivity {
    static let type = "dev.apexterminal.session"
    static let hostKey = "hostID"

    /// The activity for a session, or `nil` when there is nothing to hand over.
    ///
    /// Only the connection's identifier is carried. Not the hostname, not the user name,
    /// and certainly nothing secret: a user activity is stored by the system and can be
    /// advertised over the air, so it says which saved connection this is and lets the
    /// other device look the rest up in its own list.
    static func make(hostID: UUID, title: String) -> NSUserActivity {
        let activity = NSUserActivity(activityType: type)
        activity.title = title
        activity.userInfo = [hostKey: hostID.uuidString]
        activity.isEligibleForHandoff = true
        // Not searchable and not public: indexing is the Spotlight switch's business, and
        // it is off unless somebody turned it on.
        activity.isEligibleForSearch = false
        activity.isEligibleForPrediction = false
        return activity
    }
}
