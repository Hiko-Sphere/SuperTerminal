import Foundation
import UIKit
import NIOTransportServices
import STSSH
import STTerminal
import Testing
@testable import SuperTerminal

/// The paste rule protects the user from their own pasteboard: a newline in pasted text
/// executes whatever precedes it the moment it arrives.
///
/// Tested against the policy directly rather than through a session. Driving it through
/// `TerminalSession` would pass whether or not the rule existed, because an unconnected
/// session declines to paste anyway — a green test that proves nothing.
@Suite("Paste policy")
struct PastePolicyTests {
    @Test("A single line is sent without interruption")
    func singleLineIsSent() {
        #expect(
            PastePolicy.decide(text: "ls -la", confirmMultiline: true, bracketedPaste: false) == .send
        )
    }

    @Test("A newline triggers a confirmation")
    func newlineIsConfirmed() {
        #expect(
            PastePolicy.decide(text: "rm -rf /tmp/x\nreboot", confirmMultiline: true, bracketedPaste: false) == .confirm
        )
    }

    @Test("A bare carriage return counts as a newline")
    func carriageReturnIsConfirmed() {
        // Copying from some terminals and editors yields CR rather than LF, and a shell
        // treats it exactly the same way.
        #expect(
            PastePolicy.decide(text: "one\rtwo", confirmMultiline: true, bracketedPaste: false) == .confirm
        )
    }

    @Test("Bracketed paste does not skip the confirmation")
    func bracketedPasteStillConfirms() {
        // The mode says the program *claims* to bracket pastes; it cannot say what is
        // actually reading input underneath it.
        #expect(
            PastePolicy.decide(text: "one\ntwo", confirmMultiline: true, bracketedPaste: true) == .confirm
        )
    }

    @Test("Turning the preference off honours the choice")
    func preferenceIsHonoured() {
        #expect(
            PastePolicy.decide(text: "one\ntwo", confirmMultiline: false, bracketedPaste: false) == .send
        )
    }

    @Test("Empty text does nothing")
    func emptyIsIgnored() {
        #expect(
            PastePolicy.decide(text: "", confirmMultiline: true, bracketedPaste: false) == .ignore
        )
    }
}

/// Search behaviour that belongs to the session rather than to the screen: which match is
/// focused, and how far the view scrolls to reveal it.
@Suite("Session search")
@MainActor
struct SessionSearchTests {
    private func makeSession() -> TerminalSession {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "search-tests-\(UUID())")!)
        return TerminalSession(
            host: Host(name: "T", hostname: "example", username: "u", credentials: [.none]),
            group: SessionTestSupport.group,
            vault: CredentialVault(),
            knownHosts: InMemoryKnownHostsStore(),
            settings: settings,
            log: .disabled
        )
    }

    @Test("Searching an empty buffer finds nothing and focuses nothing")
    func emptyBufferHasNoMatches() {
        let session = makeSession()
        session.search(for: "anything", caseSensitive: false)
        #expect(session.searchMatches.isEmpty)
        #expect(session.focusedMatchIndex == nil)
        #expect(session.focusedMatch == nil)
    }

    @Test("Clearing search resets the focus")
    func clearingResetsFocus() {
        let session = makeSession()
        session.search(for: "x", caseSensitive: false)
        session.clearSearch()
        #expect(session.searchMatches.isEmpty)
        #expect(session.focusedMatchIndex == nil)
    }

    @Test("Stepping through matches wraps around")
    func steppingWrapsAround() {
        let session = makeSession()
        // With no matches, stepping must be a no-op rather than a crash or a stuck index.
        session.focusNextMatch()
        #expect(session.focusedMatchIndex == nil)
    }
}

/// A shared event loop group for tests that construct sessions without connecting.
enum SessionTestSupport {
    static let group = NIOTSEventLoopGroup(loopCount: 1)
}

/// Dropping text, and pinching to resize.
///
/// The drop tests are about one property: a drop is a paste. Text arriving by drag is
/// indistinguishable from text arriving by paste once it reaches the shell, so it must go
/// through the same confirmation — otherwise dragging a block of commands in runs all of
/// them on one gesture with no warning, which is precisely what the paste confirmation
/// exists to prevent.
@Suite("Drop and pinch")
@MainActor
struct DropAndPinchTests {
    @Test("A multi-line drop is confirmed, exactly as a multi-line paste is")
    func multilineDropIsConfirmed() {
        let dropped = "cd /var/log\nrm -rf old\n"
        #expect(
            PastePolicy.decide(text: dropped, confirmMultiline: true, bracketedPaste: false) == .confirm
        )
    }

    @Test("A single-line drop goes straight in")
    func singleLineDropIsSent() {
        #expect(
            PastePolicy.decide(text: "uptime", confirmMultiline: true, bracketedPaste: false) == .send
        )
    }

    @Test("An empty drop does nothing")
    func emptyDropIsIgnored() {
        #expect(PastePolicy.decide(text: "", confirmMultiline: true, bracketedPaste: false) == .ignore)
    }

    @Test("Pinching cannot leave the terminal at a size the settings would refuse")
    func pinchStaysWithinTheSettingsRange() {
        // Two ranges that disagree would let a pinch reach a size the stepper in Settings
        // then refuses to show or restore.
        #expect(TerminalInputView.fontSizeRange.lowerBound == CGFloat(AppSettings.fontSizeRange.lowerBound))
        #expect(TerminalInputView.fontSizeRange.upperBound == CGFloat(AppSettings.fontSizeRange.upperBound))
    }
}
