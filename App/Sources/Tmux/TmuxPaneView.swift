import STTerminal
import STTmux
import SwiftUI

/// One tmux pane, drawn with the same terminal view everything else uses.
///
/// The keyboard, the selection, the scroll wheel and the pointer are the terminal view's;
/// what changes is where the bytes come from and where they go. A pane's screen is whatever
/// tmux has sent for it, and what is typed goes back as a tmux command rather than down a
/// shell channel.
struct TmuxPaneView: UIViewRepresentable {
    @Environment(AppContainer.self) private var container
    let session: TmuxSession
    let pane: TmuxPaneID
    let screen: TerminalScreen
    let theme: TerminalTheme
    let fontSize: CGFloat
    let fontFamily: String
    let lineHeightMultiple: CGFloat
    let ligaturesEnabled: Bool
    let blinkCursor: Bool
    /// How far back this pane is scrolled, in lines.
    let scrollbackOffset: Int
    /// Whether this pane should be holding the keyboard.
    let wantsKeyboard: Bool
    let onHaptic: (Haptics.Event) -> Void
    let onCopy: (String) -> Void

    func makeUIView(context: Context) -> TerminalInputView {
        let view = TerminalInputView()
        view.shortcutRouter = container.shortcuts
        view.renderView.theme = theme
        view.renderView.fontFamily = fontFamily
        view.renderView.lineHeightMultiple = lineHeightMultiple
        view.renderView.ligaturesEnabled = ligaturesEnabled
        view.renderView.fontSize = fontSize
        context.coordinator.attach(to: view, session: session, pane: pane, onHaptic: onHaptic, onCopy: onCopy)
        return view
    }

    func updateUIView(_ view: TerminalInputView, context: Context) {
        // Rebound when the pane changes, for the same reason the terminal's own view does
        // it: SwiftUI reuses one view and the callbacks would still point at the pane it
        // was created for, so every keystroke would go to the wrong shell (D-025).
        if context.coordinator.boundPane != pane {
            context.coordinator.attach(to: view, session: session, pane: pane, onHaptic: onHaptic, onCopy: onCopy)
        }
        view.renderView.theme = theme
        let fontChanged = view.renderView.fontSize != fontSize
            || view.renderView.fontFamily != fontFamily
            || view.renderView.lineHeightMultiple != lineHeightMultiple
        view.renderView.fontFamily = fontFamily
        view.renderView.lineHeightMultiple = lineHeightMultiple
        view.renderView.ligaturesEnabled = ligaturesEnabled
        view.renderView.fontSize = fontSize
        if fontChanged { view.reportGridSizeIfChanged() }
        view.renderView.update(screen: screen)
        view.renderView.scrollbackOffset = scrollbackOffset

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
        private(set) var boundPane: TmuxPaneID?

        func attach(
            to view: TerminalInputView,
            session: TmuxSession,
            pane: TmuxPaneID,
            onHaptic: @escaping (Haptics.Event) -> Void,
            onCopy: @escaping (String) -> Void
        ) {
            boundPane = pane
            view.onInput = { data in
                Task { @MainActor in await session.send(data, to: pane) }
            }
            view.onPaste = { text in
                // No confirmation sheet here yet: a paste goes to tmux as bytes, and the
                // pane's own shell decides what to do with it. The multi-line warning is
                // the terminal session's, and giving tmux one means teaching this view
                // about the prompt coordinator — deliberately left for when the pane view
                // and the terminal view share one input path.
                Task { @MainActor in await session.send(Data(text.utf8), to: pane) }
            }
            // tmux sizes its panes itself, from the client size the session reports, so a
            // pane does not tell the server its own grid: it would fight the layout.
            view.onGridSizeChange = { _, _ in }
            view.onHaptic = onHaptic
            view.onCopy = onCopy
            // Local, over the history this pane's terminal was seeded with when it
            // appeared. tmux's own copy mode sends a control client nothing, so scrolling
            // through it would move a screen nobody can see.
            view.onScroll = { rows in
                Task { @MainActor in session.scroll(rows, in: pane) }
            }
            view.onSelectionChange = { [weak view] range in
                view?.renderView.selection = range
            }
        }
    }
}
