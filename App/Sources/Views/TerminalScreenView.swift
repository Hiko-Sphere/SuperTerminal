import STTerminal
import SwiftUI

/// Hosts the terminal grid in SwiftUI and wires input back to the session.
struct TerminalScreenView: UIViewRepresentable {
    @Environment(AppContainer.self) private var container
    let session: TerminalSession
    let theme: TerminalTheme
    let fontSize: CGFloat
    /// The font family, line height and ligature choice (D-063).
    let fontFamily: String
    let lineHeightMultiple: CGFloat
    let ligaturesEnabled: Bool
    let blinkCursor: Bool
    let confirmMultilinePaste: Bool
    /// Called when ⌘K is pressed while the terminal has the keyboard.
    let onCommandPalette: () -> Void
    /// Plays a haptic, if the user wants them.
    let onHaptic: (Haptics.Event) -> Void
    /// Copies terminal text with the clipboard-expiry setting applied.
    let onCopy: (String) -> Void
    /// ⌘F: opens the session's scrollback search.
    let onFind: () -> Void
    /// Called when a pinch asks for a different font size, so it can be persisted.
    let onFontSizeChange: (CGFloat) -> Void
    /// Whether the terminal should be holding the keyboard right now: this window is
    /// showing the session and nothing is covering it.
    ///
    /// UIKit hands first-responder status to a sheet, a search field or the lock screen
    /// and never gives it back. With a software keyboard that is invisible — it goes away
    /// and the user taps the terminal to bring it back — but with a hardware keyboard
    /// there is nothing to see and nothing to tap: typing simply stops working. So the
    /// terminal takes it back itself, whenever it should have it (D-025).
    let wantsKeyboard: Bool

    func makeUIView(context: Context) -> TerminalInputView {
        let view = TerminalInputView()
        view.shortcutRouter = container.shortcuts
        view.renderView.theme = theme
        view.renderView.fontFamily = fontFamily
        view.renderView.lineHeightMultiple = lineHeightMultiple
        view.renderView.ligaturesEnabled = ligaturesEnabled
        view.renderView.fontSize = fontSize
        context.coordinator.attach(
            to: view,
            session: session,
            confirmMultilinePaste: confirmMultilinePaste,
            onFontSizeChange: onFontSizeChange,
            onCommandPalette: onCommandPalette,
            onHaptic: onHaptic,
            onCopy: onCopy,
            onFind: onFind
        )
        return view
    }

    func updateUIView(_ view: TerminalInputView, context: Context) {
        // SwiftUI keeps one view for the whole detail column on iPad, so switching
        // sessions does not make a new one — and the callbacks installed when it was
        // created still point at the session it was created with. Every keystroke went
        // to the first session opened until this rebound them (D-025).
        if context.coordinator.boundSessionID != session.id {
            context.coordinator.attach(
                to: view,
                session: session,
                confirmMultilinePaste: confirmMultilinePaste,
                onFontSizeChange: onFontSizeChange,
                onCommandPalette: onCommandPalette,
                onHaptic: onHaptic,
                onCopy: onCopy,
                onFind: onFind
            )
        }
        view.renderView.theme = theme
        let fontChanged = view.renderView.fontSize != fontSize
            || view.renderView.fontFamily != fontFamily
            || view.renderView.lineHeightMultiple != lineHeightMultiple
        view.renderView.fontFamily = fontFamily
        view.renderView.lineHeightMultiple = lineHeightMultiple
        view.renderView.ligaturesEnabled = ligaturesEnabled
        view.renderView.fontSize = fontSize
        // A different font means a different number of cells in the same bounds, and the
        // remote program has to be told before it draws anything else.
        if fontChanged { view.reportGridSizeIfChanged() }
        view.renderView.update(screen: session.screen)
        view.renderView.scrollbackOffset = session.scrollbackOffset
        view.renderView.selection = session.selection
        view.renderView.searchMatches = session.searchMatches.map(\.range)
        view.renderView.focusedMatch = session.focusedMatch
        view.modes = session.modes
        // Not mirrored while the view has already consumed it: the view clears its own
        // latch the instant a character arrives and clears the session's synchronously,
        // but an update that lands between the two would arm it again and eat the next
        // character.
        view.controlLatched = session.controlLatched
        // Blinking is an animation; when the system asks for reduced motion the cursor
        // stays solid rather than pulsing.
        if wantsKeyboard, view.window != nil, !view.isFirstResponder {
            _ = view.becomeFirstResponder()
        } else if !wantsKeyboard, view.isFirstResponder {
            _ = view.resignFirstResponder()
        }
        let shouldBlink = blinkCursor
            && !context.environment.accessibilityReduceMotion
            && view.isFirstResponder
        view.renderView.setBlinkEnabled(shouldBlink)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        /// The session the view's callbacks currently point at.
        private(set) var boundSessionID: TerminalSession.ID?

        func attach(
            to view: TerminalInputView,
            session: TerminalSession,
            confirmMultilinePaste: Bool,
            onFontSizeChange: @escaping (CGFloat) -> Void,
            onCommandPalette: @escaping () -> Void,
            onHaptic: @escaping (Haptics.Event) -> Void,
            onCopy: @escaping (String) -> Void,
            onFind: @escaping () -> Void
        ) {
            boundSessionID = session.id
            view.onInput = { data in
                Task { @MainActor in
                    session.noteTypedInput(data)
                    await session.send(data)
                }
            }
            view.onPaste = { text in
                Task { @MainActor in
                    await session.requestPaste(text, confirmMultiline: confirmMultilinePaste)
                }
            }
            view.onScroll = { rows in
                Task { @MainActor in session.scrollBack(by: rows) }
            }
            view.onCommandPalette = { onCommandPalette() }
            view.onHaptic = { event in
                Task { @MainActor in onHaptic(event) }
            }
            view.onCopy = { text in
                Task { @MainActor in onCopy(text) }
            }
            view.onFind = {
                Task { @MainActor in onFind() }
            }
            view.onFontSizeChange = { size in
                Task { @MainActor in onFontSizeChange(size) }
            }
            view.onGridSizeChange = { columns, rows, pixelWidth, pixelHeight in
                Task { @MainActor in
                    await session.resize(
                        columns: columns,
                        rows: rows,
                        pixelWidth: pixelWidth,
                        pixelHeight: pixelHeight
                    )
                }
            }
            view.onSelectionChange = { range in
                Task { @MainActor in session.selection = range }
            }
            view.currentScreen = { [weak session] in
                MainActor.assumeIsolated { session?.screen }
            }
            view.onControlConsumed = {
                // Synchronous: `insertText` is on the main thread, and a hop would let a
                // SwiftUI update mirror the still-armed latch back into the view.
                MainActor.assumeIsolated { session.controlLatched = false }
            }
            view.onMouseEvent = { event in
                Task { @MainActor in await session.reportMouse(event) }
            }
            view.onHyperlinkTapped = { position in
                Task { @MainActor in
                    if let link = session.hyperlink(at: position) {
                        session.pendingLink = link
                    }
                }
            }
        }
    }
}
