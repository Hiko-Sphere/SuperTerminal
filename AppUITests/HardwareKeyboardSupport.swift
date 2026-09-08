import XCTest

/// The one place that knows what this simulator does to hardware key events.
///
/// **The first modifier-bearing key press an XCUITest sends after launching the app is
/// discarded before the app sees it.** Measured on 2026-09-08 with `ZZFindProbeUITests`,
/// eight probes against ⌘F on an iPhone 17 Pro simulator, each run twice:
///
/// | what was sent | did ⌘F open the find bar |
/// | --- | --- |
/// | ⌘F, first thing after the terminal opened | no |
/// | ⌘F after typing a whole shell command | no |
/// | ⌘F after a five-second settle | no |
/// | ⌘F after typing one plain character | no |
/// | ⌘F after ⌘C | **yes** |
/// | ⌘F after ⌃⌥⇧⌘Z, which the app does not bind | **yes** |
/// | ⌘F sent twice | **yes** |
/// | the same command from the Session menu, no keyboard | **yes** |
///
/// So it is not a race — waiting does not help — and it is not about ⌘F: any modified key
/// absorbs it, bound or not, while an unmodified one does not. The app's own handling is
/// fine, which the menu row and the second press both show.
///
/// It is also not once per launch. Priming on the host list and then opening a terminal
/// leaves the terminal's first ⌘F missing again — measured, three runs, three failures —
/// so the press has to be spent on the same screen as the shortcut that matters.
///
/// The fix is to spend the loss on a keystroke that means nothing, on the screen about to
/// be tested, rather than to make every test retry and hope. A test that then fails,
/// failed for a reason.
extension XCUIApplication {
    /// Spends the discarded press on a combination the app does not bind.
    ///
    /// For screens that are not a terminal. Call it once the app is actually up — after
    /// whatever `waitForExistence` the test uses to know that, not immediately after
    /// `launch()` returns: a press sent before the app is ready is dropped somewhere
    /// earlier and absorbs nothing, measured by priming in `setUp` and watching the first
    /// ⌘F go missing anyway.
    func primeModifierKeys() {
        typeKey("z", modifierFlags: [.command, .control, .option, .shift])
    }

    /// The same, for a terminal that is on screen.
    ///
    /// A terminal forwards keys it does not handle to the remote shell, so the unbound
    /// combination above cannot be used here: primed inside the terminal it reached the
    /// shell and garbled the next line the test typed, failing a plain-typing assertion
    /// that had always passed. ⌘C is a key command the terminal consumes, and
    /// `copySelection` returns immediately when nothing is selected — so it is absorbed
    /// and does nothing at all.
    func primeModifierKeysInTerminal() {
        typeKey("c", modifierFlags: .command)
    }
}
