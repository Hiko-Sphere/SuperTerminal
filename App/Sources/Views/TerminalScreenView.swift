import STTerminal
import SwiftUI

/// Hosts the terminal grid in SwiftUI and wires input back to the session.
struct TerminalScreenView: UIViewRepresentable {
    let session: TerminalSession
    let theme: TerminalTheme
    let fontSize: CGFloat
    let blinkCursor: Bool
    let confirmMultilinePaste: Bool
    /// Called when a pinch asks for a different font size, so it can be persisted.
    let onFontSizeChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> TerminalInputView {
        let view = TerminalInputView()
        view.renderView.theme = theme
        view.renderView.fontSize = fontSize
        context.coordinator.attach(
            to: view,
            session: session,
            confirmMultilinePaste: confirmMultilinePaste,
            onFontSizeChange: onFontSizeChange
        )
        return view
    }

    func updateUIView(_ view: TerminalInputView, context: Context) {
        view.renderView.theme = theme
        let fontChanged = view.renderView.fontSize != fontSize
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
        view.controlLatched = session.controlLatched
        // Blinking is an animation; when the system asks for reduced motion the cursor
        // stays solid rather than pulsing.
        let shouldBlink = blinkCursor
            && !context.environment.accessibilityReduceMotion
            && view.isFirstResponder
        view.renderView.setBlinkEnabled(shouldBlink)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        func attach(
            to view: TerminalInputView,
            session: TerminalSession,
            confirmMultilinePaste: Bool,
            onFontSizeChange: @escaping (CGFloat) -> Void
        ) {
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
            view.onFontSizeChange = { size in
                Task { @MainActor in onFontSizeChange(size) }
            }
            view.onGridSizeChange = { columns, rows in
                Task { @MainActor in await session.resize(columns: columns, rows: rows) }
            }
            view.onSelectionChange = { range in
                Task { @MainActor in session.selection = range }
            }
            view.currentScreen = { [weak session] in
                MainActor.assumeIsolated { session?.screen }
            }
            view.onControlConsumed = {
                Task { @MainActor in session.controlLatched = false }
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
