import Foundation
import STCloudflare

/// What each diagnostic result *means*, separated from the I/O that produced it (D-053).
///
/// A diagnostics screen is only worth having if its reasoning is right, and reasoning is
/// exactly the part that can be quietly wrong — a hostname reported as fine when the token
/// will not validate, a missing service token reported as a warning when it is the reason
/// nothing will connect. Keeping it a pure function over what came back is what lets that
/// reasoning have tests.
enum AccessDiagnostics {
    /// What is known about the stored session for this connection.
    enum SessionState: Equatable {
        /// There is no Access application, so the question does not arise.
        case notApplicable
        case notSignedIn
        case valid(until: Date)
        case expired
        /// A token is stored but will not validate — worse than none, because it is why a
        /// connection fails with something that looks like the server's fault.
        case unusable
        case serviceTokenStored
        case serviceTokenMissing
    }

    /// The hostname could not be reached at all.
    static func steps(unreachable message: String?) -> [AccessDiagnosticsView.Step] {
        [
            .init(
                title: String(localized: "Reaching the hostname"),
                outcome: .bad(message ?? String(localized: "The hostname could not be reached."))
            )
        ]
    }

    static func steps(
        for probe: AccessDiscovery.Probe,
        session: SessionState
    ) -> [AccessDiagnosticsView.Step] {
        var steps: [AccessDiagnosticsView.Step] = [
            .init(
                title: String(localized: "Reaching the hostname"),
                outcome: .good(String(localized: "The Cloudflare edge answered."))
            )
        ]

        switch probe {
        case .unprotected:
            // A legitimate configuration, and worth saying out loud rather than passing
            // silently: the tunnel works and nothing is checking who uses it.
            steps.append(
                .init(
                    title: String(localized: "Access policy"),
                    outcome: .warning(
                        String(localized: "No Access application guards this hostname. The tunnel still works, but nothing is checking who connects.")
                    )
                )
            )
            return steps

        case let .protected(info):
            steps.append(
                .init(
                    title: String(localized: "Access policy"),
                    outcome: .good(String(localized: "Protected by \(info.appHostname)."))
                )
            )
            steps.append(.init(title: String(localized: "Team domain"), outcome: .good(info.authDomain)))
        }

        switch session {
        case .notApplicable:
            break
        case .notSignedIn:
            steps.append(
                .init(
                    title: String(localized: "Session"),
                    outcome: .warning(String(localized: "Not signed in yet. Connecting will open the sign-in page."))
                )
            )
        case let .valid(until):
            steps.append(
                .init(
                    title: String(localized: "Session"),
                    outcome: .good(
                        String(localized: "Valid until \(until.formatted(date: .abbreviated, time: .shortened)).")
                    )
                )
            )
        case .expired:
            steps.append(
                .init(
                    title: String(localized: "Session"),
                    outcome: .warning(String(localized: "Expired. Connecting will sign in again."))
                )
            )
        case .unusable:
            steps.append(
                .init(
                    title: String(localized: "Session"),
                    outcome: .bad(String(localized: "The stored session could not be validated. Sign out and connect again."))
                )
            )
        case .serviceTokenStored:
            steps.append(
                .init(
                    title: String(localized: "Service token"),
                    outcome: .good(String(localized: "Stored on this device."))
                )
            )
        case .serviceTokenMissing:
            // Not a warning: this connection cannot open at all until it is entered.
            steps.append(
                .init(
                    title: String(localized: "Service token"),
                    outcome: .bad(String(localized: "No service token is stored. Edit the connection and enter its client ID and secret."))
                )
            )
        }

        return steps
    }
}

extension AccessDiagnosticsView.Step.Outcome: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.good(a), .good(b)), let (.warning(a), .warning(b)), let (.bad(a), .bad(b)): a == b
        default: false
        }
    }

    /// Whether this is something the user has to do something about.
    var needsAttention: Bool {
        switch self {
        case .good: false
        case .warning, .bad: true
        }
    }
}
