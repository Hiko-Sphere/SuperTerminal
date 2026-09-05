import SwiftUI
import UIKit

/// The palette's query field, backed by UIKit so Escape and the arrows are real key
/// commands. A SwiftUI `TextField` with `onKeyPress` never saw a hardware Escape while it
/// had focus (a UI test typing real keys showed the palette staying open), and the arrows
/// have to beat the caret, which only `wantsPriorityOverSystemBehavior` can promise.
struct PaletteQueryField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onSubmit: () -> Void
    let onMove: (Int) -> Void
    let onEscape: () -> Void

    func makeUIView(context: Context) -> PaletteTextField {
        let field = PaletteTextField()
        field.placeholder = placeholder
        field.font = UIFont.preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.returnKeyType = .go
        field.clearButtonMode = .never
        field.accessibilityIdentifier = "palette-query"
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.onMove = onMove
        field.onEscape = onEscape
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: PaletteTextField, context: Context) {
        if field.text != text { field.text = text }
        field.onMove = onMove
        field.onEscape = onEscape
        context.coordinator.onSubmit = onSubmit
        context.coordinator.text = $text
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, onSubmit: onSubmit) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var text: Binding<String>
        var onSubmit: () -> Void
        init(text: Binding<String>, onSubmit: @escaping () -> Void) { self.text = text; self.onSubmit = onSubmit }
        @objc func changed(_ field: UITextField) { text.wrappedValue = field.text ?? "" }
        func textFieldShouldReturn(_ textField: UITextField) -> Bool { onSubmit(); return false }
    }
}

final class PaletteTextField: UITextField {
    var onMove: ((Int) -> Void)?
    var onEscape: (() -> Void)?

    /// Focus on appearance: the palette exists to be typed into. Done here rather than
    /// on creation, because a field not yet in a window cannot become first responder.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, !isFirstResponder { _ = becomeFirstResponder() }
    }

    override var keyCommands: [UIKeyCommand]? {
        let up = UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(moveUp))
        let down = UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(moveDown))
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escape))
        for command in [up, down, escape] { command.wantsPriorityOverSystemBehavior = true }
        return [up, down, escape] + (super.keyCommands ?? [])
    }

    /// Escape also handled here: if the key command path is bypassed for a focused text
    /// field, the press still arrives, and dismissing twice is harmless.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.key?.keyCode == .keyboardEscape }) {
            onEscape?()
            return
        }
        super.pressesBegan(presses, with: event)
    }

    @objc private func moveUp() { onMove?(-1) }
    @objc private func moveDown() { onMove?(1) }
    @objc private func escape() { onEscape?() }
}
