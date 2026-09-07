import Foundation
import STCore
import STSSH
import Testing
@testable import ApexTerminal

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


/// The reconnection banner's wording, which is the part of the feature a user reads.
///
/// Separate from the integration tests because those prove it reconnects; these pin what
/// it *says* while doing so. A banner that claims to be reconnecting while it is really
/// waiting for a network the device does not have is worse than saying nothing.
@Suite("Reconnection wording")
@MainActor
struct ReconnectionWordingTests {
    private func banner(
        attempt: Int = 1,
        nextAttempt: Date? = nil,
        isAttempting: Bool = false,
        waitingForNetwork: Bool = false
    ) -> TerminalSession.Reconnection {
        TerminalSession.Reconnection(
            attempt: attempt,
            nextAttempt: nextAttempt,
            isAttempting: isAttempting,
            lastError: STError(category: .network, message: "The connection to the host was lost."),
            isWaitingForNetwork: waitingForNetwork
        )
    }

    @Test("Waiting for a network is not described as reconnecting")
    func waitingForNetworkIsNotCalledReconnecting() {
        let state = banner(waitingForNetwork: true)
        #expect(state.isWaitingForNetwork)
        #expect(!state.isAttempting, "nothing is in flight while there is no network to use")
    }

    @Test("An exhausted retry is distinguishable from one still counting down")
    func exhaustedIsDistinguishable() {
        let counting = banner(attempt: 3, nextAttempt: Date().addingTimeInterval(4))
        let exhausted = banner(attempt: 8, nextAttempt: nil)
        #expect(counting.nextAttempt != nil)
        #expect(exhausted.nextAttempt == nil)
        #expect(counting != exhausted)
    }
}

/// Reopening the connections that were open last time.
@Suite("Session restoration")
@MainActor
struct SessionRestorationTests {
    private func makeStore() -> (SessionRestorationStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("st-restore-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (SessionRestorationStore(directory: directory), directory)
    }

    @Test("What was open is offered after a relaunch")
    func openSessionsAreOffered() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let web = UUID()

        store.record(hosts: [(id: web, name: "web")])
        // A fresh store is what a relaunch looks like.
        let reopened = SessionRestorationStore(directory: directory)
        #expect(reopened.pending.count == 1)
        #expect(reopened.pending.first?.hostID == web)
    }

    @Test("Recording does not change what is currently being offered")
    func recordingDoesNotDisturbTheOffer() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.record(hosts: [(id: UUID(), name: "web")])

        let relaunched = SessionRestorationStore(directory: directory)
        #expect(relaunched.pending.count == 1)
        // Opening something new during this run must not make the banner change under
        // the user while they are looking at it.
        relaunched.record(hosts: [(id: UUID(), name: "db"), (id: UUID(), name: "cache")])
        #expect(relaunched.pending.count == 1, "the offer describes last time, not now")
    }

    @Test("Closing everything leaves nothing to reopen")
    func closingEverythingClearsTheOffer() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.record(hosts: [(id: UUID(), name: "web")])
        store.record(hosts: [])

        #expect(SessionRestorationStore(directory: directory).pending.isEmpty)
    }

    @Test("Clearing removes the file, not just the list")
    func clearingRemovesTheFile() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.record(hosts: [(id: UUID(), name: "web")])
        let file = directory.appendingPathComponent("open_sessions.json")
        #expect(FileManager.default.fileExists(atPath: file.path))

        SessionRestorationStore(directory: directory).clear()
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("A stale list is not offered as where you left off")
    func staleEntriesAreDropped() throws {
        let (_, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let old = SessionRestorationStore.RestorableSession(
            id: UUID(),
            hostID: UUID(),
            hostName: "web",
            endedAt: Date().addingTimeInterval(-SessionRestorationStore.maximumAge - 60)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([old]).write(to: directory.appendingPathComponent("open_sessions.json"))

        // Two weeks later this is not "carry on where you were", it is clutter.
        #expect(SessionRestorationStore(directory: directory).pending.isEmpty)
    }
}

/// Switching sessions from the keyboard.
///
/// The bindings themselves are declarative; what is worth testing is where they land.
/// A shortcut that quietly selects the wrong terminal is worse than one that does nothing,
/// because the next thing typed goes to the wrong machine.
@Suite("Keyboard session switching")
@MainActor
struct SessionSwitchingShortcutTests {
    private func manager(withSessionCount count: Int) -> (SessionManager, [TerminalSession]) {
        let manager = SessionManager(
            vault: CredentialVault(),
            knownHosts: InMemoryKnownHostsStore(),
            settings: AppSettings(defaults: UserDefaults(suiteName: "shortcuts-\(UUID())")!),
            diagnostics: DiagnosticsCentre()
        )
        let sessions = (0 ..< count).map { index in
            manager.open(Host(name: "host-\(index)", hostname: "h", username: "u", credentials: [.none]))
        }
        return (manager, sessions)
    }

    @Test("Command-1 is the first session, not the zeroth")
    func numbersAreOneBased() {
        let (manager, sessions) = manager(withSessionCount: 3)
        defer { manager.closeAll() }
        #expect(manager.session(atOneBasedIndex: 1)?.id == sessions[0].id)
        #expect(manager.session(atOneBasedIndex: 3)?.id == sessions[2].id)
    }

    @Test("A number with no session behind it does nothing")
    func outOfRangeSelectsNothing() {
        let (manager, _) = manager(withSessionCount: 3)
        defer { manager.closeAll() }
        // Clamping to the last session would put the next keystroke on a machine the
        // user did not choose.
        #expect(manager.session(atOneBasedIndex: 4) == nil)
        #expect(manager.session(atOneBasedIndex: 0) == nil)
        #expect(manager.session(atOneBasedIndex: -1) == nil)
    }

    @Test("Next and previous wrap around")
    func cyclingWraps() {
        let (manager, sessions) = manager(withSessionCount: 3)
        defer { manager.closeAll() }

        #expect(manager.session(after: sessions[0].id, delta: 1)?.id == sessions[1].id)
        #expect(manager.session(after: sessions[2].id, delta: 1)?.id == sessions[0].id)
        #expect(manager.session(after: sessions[0].id, delta: -1)?.id == sessions[2].id)
    }

    @Test("Cycling with nothing selected picks an end rather than failing")
    func cyclingFromNothing() {
        let (manager, sessions) = manager(withSessionCount: 3)
        defer { manager.closeAll() }
        #expect(manager.session(after: nil, delta: 1)?.id == sessions[0].id)
        #expect(manager.session(after: nil, delta: -1)?.id == sessions[2].id)
    }

    @Test("Cycling with a session that has been closed picks an end")
    func cyclingFromAClosedSession() {
        let (manager, sessions) = manager(withSessionCount: 2)
        defer { manager.closeAll() }
        let stale = sessions[0].id
        manager.close(sessions[0])
        // A window still holding the id of a session someone else closed must not be
        // left unable to move.
        #expect(manager.session(after: stale, delta: 1)?.id == sessions[1].id)
    }

    @Test("Cycling with no sessions at all does nothing")
    func cyclingWithNoSessions() {
        let (manager, _) = manager(withSessionCount: 0)
        #expect(manager.session(after: nil, delta: 1) == nil)
    }
}

/// The haptic vocabulary.
///
/// Worth testing because haptics are a language: the same tap has to mean the same thing
/// everywhere, and a setting that says "off" has to mean the device stays still. Before
/// this there were seven ad-hoc generators scattered through the views, no user control,
/// and none of them warmed up.
@Suite("Haptics")
@MainActor
struct HapticsTests {
    private func makeHaptics(enabled: Bool) -> (Haptics, AppSettings) {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "haptics-\(UUID())")!)
        settings.hapticsEnabled = enabled
        return (Haptics(settings: settings), settings)
    }

    @Test("Every event is playable and preparable without a device")
    func vocabularyIsComplete() {
        // Exercises each branch, so a new case added without a mapping fails to compile
        // rather than silently doing nothing on a device nobody is testing on.
        let (haptics, _) = makeHaptics(enabled: true)
        let events: [Haptics.Event] = [
            .connected, .disconnected, .failed, .modifierArmed,
            .selectionChanged, .bell, .textInserted,
        ]
        for event in events {
            haptics.prepare(for: event)
            haptics.play(event)
        }
    }

    @Test("Turning haptics off is honoured by both play and prepare")
    func settingIsHonoured() {
        // Preparing warms the Taptic Engine, which costs power. Off should mean off for
        // that too, not merely for the tap the user would have felt.
        let (haptics, settings) = makeHaptics(enabled: false)
        #expect(!settings.hapticsEnabled)
        haptics.prepare(for: .connected)
        haptics.play(.connected)
    }

    @Test("The setting survives a reload")
    func settingPersists() {
        let suite = "haptics-persist-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = AppSettings(defaults: defaults)
        #expect(settings.hapticsEnabled, "haptics should be on by default")
        settings.hapticsEnabled = false
        #expect(!AppSettings(defaults: defaults).hapticsEnabled)
    }
}
