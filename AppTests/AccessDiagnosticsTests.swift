import Foundation
import STCloudflare
import Testing

@testable import ApexTerminal

/// What the Access diagnostics screen concludes, for every state it can be in (D-053).
///
/// The network probe has its own tests and the live end-to-end run is H-4; what is checked
/// here is the reasoning on top, because that is the part that can be quietly wrong. A
/// screen that reported a hostname as fine while the stored token would not validate would
/// be worse than no screen at all — it would send someone looking at the server.
@Suite("Access diagnostics")
struct AccessDiagnosticsTests {
    private let appInfo = AccessAppInfo(
        authDomain: "example.cloudflareaccess.com",
        appAUD: "aud-value",
        appHostname: "ssh.example.com"
    )

    @Test("An unreachable hostname is the only thing reported, because nothing else was learned")
    func unreachableStopsThere() {
        let steps = AccessDiagnostics.steps(unreachable: "The network connection was lost.")
        #expect(steps.count == 1)
        #expect(steps[0].outcome == .bad("The network connection was lost."))
        // No invented follow-on: with no answer from the edge, everything after it is
        // unknown rather than fine.
        #expect(steps[0].outcome.needsAttention)
    }

    @Test("A hostname with no Access application is a warning, not a pass")
    func unprotectedIsAWarning() {
        let steps = AccessDiagnostics.steps(for: .unprotected, session: .notApplicable)
        #expect(steps.count == 2)
        #expect(steps[0].outcome == .good("The Cloudflare edge answered."))
        // It works, and it is also nobody checking who connects. Reporting it as simply
        // fine would hide a real exposure behind a green tick.
        guard case .warning = steps[1].outcome else {
            Issue.record("expected a warning, got \(steps[1].outcome)")
            return
        }
        #expect(steps.allSatisfy { !$0.title.isEmpty })
    }

    @Test("A protected hostname names the application and the team domain")
    func protectedNamesTheApplication() {
        let steps = AccessDiagnostics.steps(for: .protected(appInfo), session: .notSignedIn)
        #expect(steps.count == 4)
        #expect(steps[1].outcome == .good("Protected by ssh.example.com."))
        #expect(steps[2].outcome == .good("example.cloudflareaccess.com"))
    }

    @Test("Each session state gets the severity it deserves")
    func sessionSeverities() {
        func lastOutcome(_ session: AccessDiagnostics.SessionState) -> AccessDiagnosticsView.Step.Outcome {
            AccessDiagnostics.steps(for: .protected(appInfo), session: session).last!.outcome
        }

        // Not signed in yet is normal: connecting will sign in.
        #expect(lastOutcome(.notSignedIn).needsAttention)
        guard case .warning = lastOutcome(.notSignedIn) else { Issue.record("notSignedIn"); return }

        // Expired is the same shape: it self-heals on the next connection.
        guard case .warning = lastOutcome(.expired) else { Issue.record("expired"); return }

        // A stored token that will not validate is *worse* than none, because it is the
        // one that makes a connection fail in a way that looks like the server's fault.
        guard case .bad = lastOutcome(.unusable) else { Issue.record("unusable"); return }

        // A missing service token means this connection cannot open at all.
        guard case .bad = lastOutcome(.serviceTokenMissing) else { Issue.record("serviceTokenMissing"); return }

        guard case .good = lastOutcome(.serviceTokenStored) else { Issue.record("serviceTokenStored"); return }
        guard case .good = lastOutcome(.valid(until: Date().addingTimeInterval(3600))) else {
            Issue.record("valid")
            return
        }
    }

    @Test("A valid session says when it runs out, so the answer is checkable")
    func validSessionNamesItsExpiry() {
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let steps = AccessDiagnostics.steps(for: .protected(appInfo), session: .valid(until: expiry))
        guard case let .good(text) = steps.last?.outcome else {
            Issue.record("expected a good outcome")
            return
        }
        #expect(text.contains(expiry.formatted(date: .abbreviated, time: .shortened)))
    }

    @Test("Nothing reports a problem when everything is in order")
    func aHealthySetupIsQuiet() {
        let steps = AccessDiagnostics.steps(
            for: .protected(appInfo),
            session: .valid(until: Date().addingTimeInterval(3600))
        )
        #expect(steps.allSatisfy { !$0.outcome.needsAttention })
    }
}
