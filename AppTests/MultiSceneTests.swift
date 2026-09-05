import Foundation
import STCore
import STSSH
import Testing
@testable import SuperTerminal

/// Windows on iPad.
///
/// The sessions themselves are shared — they are live connections and belong to the app
/// — but everything about *presentation* belongs to the window. These tests exist because
/// the first implementation kept the selection in `SessionManager`, where a second window
/// silently changed what the first one was showing.
@Suite("Multiple windows")
@MainActor
struct MultiSceneTests {
    private func makeManager() -> SessionManager {
        SessionManager(
            vault: CredentialVault(),
            knownHosts: InMemoryKnownHostsStore(),
            settings: AppSettings(defaults: UserDefaults(suiteName: "scenes-\(UUID())")!),
            diagnostics: DiagnosticsCentre()
        )
    }

    private func host(_ name: String) -> Host {
        Host(name: name, hostname: "example.invalid", username: "u", credentials: [.none])
    }

    @Test("Each window has its own selection")
    func selectionIsPerWindow() {
        let first = SceneState()
        let second = SceneState()
        let a = UUID()
        let b = UUID()

        first.selectedSessionID = a
        second.selectedSessionID = b

        #expect(first.selectedSessionID == a)
        #expect(second.selectedSessionID == b)
        #expect(first.id != second.id, "windows must be distinguishable to claim a session")
    }

    @Test("Opening a session does not decide what any window shows")
    func openingDoesNotSelect() {
        let manager = makeManager()
        let session = manager.open(host("one"))
        defer { manager.closeAll() }

        // Which window displays it is the window's business; the manager only owns the
        // connection.
        #expect(manager.owner(ofSessionWithID: session.id) == nil)
    }

    @Test("Claiming a session takes it from the window that held it")
    func claimTransfers() {
        let manager = makeManager()
        let session = manager.open(host("one"))
        defer { manager.closeAll() }
        let first = SceneState()
        let second = SceneState()

        manager.claimDisplay(ofSessionWithID: session.id, by: first.id)
        #expect(manager.owner(ofSessionWithID: session.id) == first.id)

        manager.claimDisplay(ofSessionWithID: session.id, by: second.id)
        #expect(manager.owner(ofSessionWithID: session.id) == second.id)
    }

    @Test("A window leaving cannot revoke the claim of the window that took over")
    func staleReleaseIsIgnored() {
        // SwiftUI decides the order: the new window's onAppear can run before the old
        // window's onDisappear. An unconditional release would leave the session owned by
        // nobody and shown by the window that is on screen — which then reports no size.
        let manager = makeManager()
        let session = manager.open(host("one"))
        defer { manager.closeAll() }
        let leaving = SceneState()
        let arriving = SceneState()

        manager.claimDisplay(ofSessionWithID: session.id, by: leaving.id)
        manager.claimDisplay(ofSessionWithID: session.id, by: arriving.id)
        manager.releaseDisplay(ofSessionWithID: session.id, by: leaving.id)

        #expect(manager.owner(ofSessionWithID: session.id) == arriving.id)
    }

    @Test("Releasing as the holder gives the session up")
    func releaseByHolderWorks() {
        let manager = makeManager()
        let session = manager.open(host("one"))
        defer { manager.closeAll() }
        let scene = SceneState()

        manager.claimDisplay(ofSessionWithID: session.id, by: scene.id)
        manager.releaseDisplay(ofSessionWithID: session.id, by: scene.id)
        #expect(manager.owner(ofSessionWithID: session.id) == nil)
    }

    @Test("A new window takes an unclaimed session, not one already on screen")
    func newWindowPicksAnUnclaimedSession() {
        let manager = makeManager()
        let shown = manager.open(host("one"))
        let spare = manager.open(host("two"))
        defer { manager.closeAll() }
        let existing = SceneState()
        manager.claimDisplay(ofSessionWithID: shown.id, by: existing.id)

        // Opening a second window should not empty the first one.
        #expect(manager.firstUnclaimedSession()?.id == spare.id)
    }

    @Test("A new window shows nothing when every session is already on screen")
    func newWindowShowsNothingWhenAllClaimed() {
        let manager = makeManager()
        let only = manager.open(host("one"))
        defer { manager.closeAll() }
        manager.claimDisplay(ofSessionWithID: only.id, by: SceneState().id)

        #expect(manager.firstUnclaimedSession() == nil)
    }

    @Test("Closing a session forgets which window was showing it")
    func closingClearsOwnership() {
        let manager = makeManager()
        let session = manager.open(host("one"))
        let scene = SceneState()
        manager.claimDisplay(ofSessionWithID: session.id, by: scene.id)

        manager.close(session)
        // A stale entry would make a later session with a reused identity appear to be
        // owned by a window that has gone.
        #expect(manager.displayOwners.isEmpty)
    }

    @Test("Closing everything forgets every claim")
    func closeAllClearsOwnership() {
        let manager = makeManager()
        let first = manager.open(host("one"))
        let second = manager.open(host("two"))
        manager.claimDisplay(ofSessionWithID: first.id, by: SceneState().id)
        manager.claimDisplay(ofSessionWithID: second.id, by: SceneState().id)

        manager.closeAll()
        #expect(manager.displayOwners.isEmpty)
        #expect(manager.sessions.isEmpty)
    }

    @Test("Looking a session up by identity")
    func lookupByID() {
        let manager = makeManager()
        let session = manager.open(host("one"))
        defer { manager.closeAll() }

        #expect(manager.session(withID: session.id)?.id == session.id)
        #expect(manager.session(withID: nil) == nil)
        #expect(manager.session(withID: UUID()) == nil)
    }
}

/// Switching which session a window shows.
///
/// Separate from the window tests because the failure it guards against is not about two
/// windows at all: a split view reuses one view for whichever session is selected, so the
/// claim has to move with the selection rather than with the view's lifetime.
@Suite("Switching sessions in one window")
@MainActor
struct SessionSwitchingTests {
    private func makeManager() -> SessionManager {
        SessionManager(
            vault: CredentialVault(),
            knownHosts: InMemoryKnownHostsStore(),
            settings: AppSettings(defaults: UserDefaults(suiteName: "switch-\(UUID())")!),
            diagnostics: DiagnosticsCentre()
        )
    }

    @Test("Selecting a different session moves the claim with it")
    func claimFollowsTheSelection() {
        let manager = makeManager()
        let first = manager.open(Host(name: "a", hostname: "h", username: "u", credentials: [.none]))
        let second = manager.open(Host(name: "b", hostname: "h", username: "u", credentials: [.none]))
        defer { manager.closeAll() }
        let scene = SceneState()

        manager.claimDisplay(ofSessionWithID: first.id, by: scene.id)
        // What the view does when the selection changes under it.
        manager.releaseDisplay(ofSessionWithID: first.id, by: scene.id)
        manager.claimDisplay(ofSessionWithID: second.id, by: scene.id)

        #expect(manager.owner(ofSessionWithID: second.id) == scene.id)
        #expect(manager.owner(ofSessionWithID: first.id) == nil, "the old session should be free for another window")
    }
}
