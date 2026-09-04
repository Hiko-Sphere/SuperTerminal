import STTerminal
import SwiftUI

/// Hosts the terminal grid in SwiftUI and wires input back to the session.
struct TerminalScreenView: UIViewRepresentable {
    let session: TerminalSession
    let theme: TerminalTheme
    let fontSize: CGFloat
    let blinkCursor: Bool

    func makeUIView(context: Context) -> TerminalInputView {
        let view = TerminalInputView()
        view.renderView.theme = theme
        view.renderView.fontSize = fontSize
        context.coordinator.attach(to: view, session: session)
        return view
    }

    func updateUIView(_ view: TerminalInputView, context: Context) {
        view.renderView.theme = theme
        view.renderView.fontSize = fontSize
        view.renderView.update(screen: session.screen)
        view.renderView.scrollbackOffset = session.scrollbackOffset
        view.modes = session.modes
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
        func attach(to view: TerminalInputView, session: TerminalSession) {
            view.onInput = { data in
                Task { @MainActor in await session.send(data) }
            }
            view.onPaste = { text in
                Task { @MainActor in await session.paste(text) }
            }
            view.onScroll = { rows in
                Task { @MainActor in session.scrollBack(by: rows) }
            }
            view.onGridSizeChange = { columns, rows in
                Task { @MainActor in await session.resize(columns: columns, rows: rows) }
            }
        }
    }
}
