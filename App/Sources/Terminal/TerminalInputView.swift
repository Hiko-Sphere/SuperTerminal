import STTerminal
import UIKit

/// Translates keyboard, pointer and gesture input into the bytes a terminal expects.
///
/// This is where a mobile SSH client is won or lost. A desktop terminal receives key
/// codes; iOS gives an app text insertion, `UIPress` events, key commands and gestures,
/// and each has to be mapped onto the right escape sequence — including the ones that
/// change meaning depending on the mode the remote program has set.
final class TerminalInputView: UIView, UIKeyInput {
    /// Called with bytes destined for the remote host.
    var onInput: ((Data) -> Void)?
    /// Called when the user scrolls the scrollback.
    var onScroll: ((Int) -> Void)?
    /// Called when the grid size changes because the view was resized.
    var onGridSizeChange: ((Int, Int) -> Void)?
    /// Called when the user asks to paste, so the session can apply bracketed paste.
    var onPaste: ((String) -> Void)?
    /// Called when a selection is made or cleared, so the UI can offer Copy.
    var onSelectionChange: ((TerminalRange?) -> Void)?
    /// Supplies the current screen so gestures can resolve positions and extract text.
    var currentScreen: (() -> TerminalScreen?)?

    /// Modes the remote program has set, which change what several keys send.
    var modes = TerminalModes()

    /// Whether the on-screen Control key is armed for the next character.
    ///
    /// The latch has to live here rather than in the button that sets it, because typed
    /// characters arrive through `insertText` on this view. A latch held anywhere else
    /// can be toggled and displayed but can never actually modify a keystroke — which is
    /// how a Control key ends up looking like it works and doing nothing.
    var controlLatched = false
    /// Called once a latched Control has been applied, so the UI can un-highlight it.
    var onControlConsumed: (() -> Void)?

    let renderView = TerminalRenderView()

    private var lastReportedGrid: (columns: Int, rows: Int) = (0, 0)
    private var selectionAnchor: TerminalPosition?

    // MARK: - Lifecycle

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(renderView)
        renderView.frame = bounds
        renderView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        isUserInteractionEnabled = true
        installGestures()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TerminalInputView is created in code, never from a storyboard")
    }

    override var canBecomeFirstResponder: Bool { true }

    /// Only offer Copy while something is selected, so the edit menu never shows an
    /// action that would do nothing.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(copySelection):
            return renderView.selection != nil
        default:
            return super.canPerformAction(action, withSender: sender)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { renderView.setNeedsDisplay() }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { renderView.setNeedsDisplay() }
        return resigned
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Opening a terminal means wanting to type in it. Making the view first responder
        // as soon as it is on screen raises the keyboard immediately, rather than making
        // the user tap the terminal before they can use it.
        if window != nil, !isFirstResponder {
            _ = becomeFirstResponder()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let grid = renderView.gridSize(for: bounds.size)
        guard grid.columns != lastReportedGrid.columns || grid.rows != lastReportedGrid.rows else { return }
        lastReportedGrid = grid
        onGridSizeChange?(grid.columns, grid.rows)
    }

    // MARK: - UIKeyInput

    var hasText: Bool { true }

    /// The software keyboard sends text through here, one insertion at a time.
    func insertText(_ text: String) {
        if controlLatched, let scalar = text.unicodeScalars.first,
           let control = Self.controlByte(for: scalar)
        {
            controlLatched = false
            onControlConsumed?()
            send(Data([control]))
            return
        }
        if controlLatched {
            // The latch applies to the next character whatever it is; a character with no
            // control equivalent simply consumes it rather than being sent as a literal
            // the user did not intend.
            controlLatched = false
            onControlConsumed?()
            return
        }
        // A newline from the on-screen keyboard means Return, which a terminal expects as
        // carriage return, not line feed.
        let normalised = text == "\n" ? "\r" : text
        send(Data(normalised.utf8))
    }

    func deleteBackward() {
        // Terminals overwhelmingly expect DEL rather than BS for the backspace key; this
        // matches the `erase = ^?` default that OpenSSH negotiates.
        send(Data([0x7F]))
    }

    var keyboardType: UIKeyboardType {
        get { .asciiCapable }
        set { _ = newValue }
    }

    var autocorrectionType: UITextAutocorrectionType {
        get { .no }
        set { _ = newValue }
    }

    var autocapitalizationType: UITextAutocapitalizationType {
        get { .none }
        set { _ = newValue }
    }

    var spellCheckingType: UITextSpellCheckingType {
        get { .no }
        set { _ = newValue }
    }

    var smartQuotesType: UITextSmartQuotesType {
        get { .no }
        set { _ = newValue }
    }

    var smartDashesType: UITextSmartDashesType {
        get { .no }
        set { _ = newValue }
    }

    var smartInsertDeleteType: UITextSmartInsertDeleteType {
        get { .no }
        set { _ = newValue }
    }

    // MARK: - Hardware keyboard

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled: Set<UIPress> = []
        for press in presses {
            guard let key = press.key, let bytes = encode(key) else {
                unhandled.insert(press)
                continue
            }
            send(bytes)
        }
        if !unhandled.isEmpty {
            super.pressesBegan(unhandled, with: event)
        }
    }

    /// Maps a hardware key press to the bytes a terminal expects.
    ///
    /// Returns `nil` for keys that should fall through to the system — so ⌘C still copies
    /// and ⌘K still reaches the app's own shortcuts, rather than being swallowed and sent
    /// to the remote host as gibberish.
    func encode(_ key: UIKey) -> Data? {
        let modifiers = key.modifierFlags

        // Command belongs to the app and the system, never to the remote host.
        if modifiers.contains(.command) { return nil }

        if modifiers.contains(.control), let scalar = key.charactersIgnoringModifiers.unicodeScalars.first {
            if let control = Self.controlByte(for: scalar) { return Data([control]) }
        }

        let escapePrefix = modifiers.contains(.alternate) ? Data([0x1B]) : Data()

        switch key.keyCode {
        case .keyboardUpArrow: return cursorKey("A")
        case .keyboardDownArrow: return cursorKey("B")
        case .keyboardRightArrow: return cursorKey("C")
        case .keyboardLeftArrow: return cursorKey("D")
        case .keyboardHome: return cursorKey("H")
        case .keyboardEnd: return cursorKey("F")
        case .keyboardPageUp: return Data("\u{1B}[5~".utf8)
        case .keyboardPageDown: return Data("\u{1B}[6~".utf8)
        case .keyboardDeleteForward: return Data("\u{1B}[3~".utf8)
        case .keyboardDeleteOrBackspace: return Data([0x7F])
        case .keyboardReturnOrEnter: return Data([0x0D])
        case .keyboardTab:
            return modifiers.contains(.shift) ? Data("\u{1B}[Z".utf8) : Data([0x09])
        case .keyboardEscape: return Data([0x1B])
        case .keyboardF1: return Data("\u{1B}OP".utf8)
        case .keyboardF2: return Data("\u{1B}OQ".utf8)
        case .keyboardF3: return Data("\u{1B}OR".utf8)
        case .keyboardF4: return Data("\u{1B}OS".utf8)
        case .keyboardF5: return Data("\u{1B}[15~".utf8)
        case .keyboardF6: return Data("\u{1B}[17~".utf8)
        case .keyboardF7: return Data("\u{1B}[18~".utf8)
        case .keyboardF8: return Data("\u{1B}[19~".utf8)
        case .keyboardF9: return Data("\u{1B}[20~".utf8)
        case .keyboardF10: return Data("\u{1B}[21~".utf8)
        case .keyboardF11: return Data("\u{1B}[23~".utf8)
        case .keyboardF12: return Data("\u{1B}[24~".utf8)
        default:
            break
        }

        guard !key.characters.isEmpty else { return nil }
        if !escapePrefix.isEmpty {
            // Option is Meta: `ESC` followed by the character, which is what readline and
            // Emacs bindings expect.
            return escapePrefix + Data(key.characters.utf8)
        }
        // Plain characters arrive through `insertText` as well; returning nil here avoids
        // sending them twice.
        return nil
    }

    /// Arrow and Home/End keys change encoding when the program sets application cursor
    /// mode — the difference between arrows working in `vim` and inserting letters.
    private func cursorKey(_ letter: String) -> Data {
        Data((modes.applicationCursorKeys ? "\u{1B}O\(letter)" : "\u{1B}[\(letter)").utf8)
    }

    static func controlByte(for scalar: Unicode.Scalar) -> UInt8? {
        switch scalar {
        case "a" ... "z": UInt8(scalar.value - 0x60)
        case "A" ... "Z": UInt8(scalar.value - 0x40)
        case "@": 0x00
        case "[": 0x1B
        case "\\": 0x1C
        case "]": 0x1D
        case "^": 0x1E
        case "_": 0x1F
        case " ": 0x00
        case "?": 0x7F
        default: nil
        }
    }

    // MARK: - Key commands

    /// Shortcuts the app itself handles. Declaring them makes them discoverable in the
    /// ⌘-hold overlay on iPad, which is how people find shortcuts at all.
    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(
                title: "Copy",
                action: #selector(copySelection),
                input: "c",
                modifierFlags: .command
            ),
            UIKeyCommand(
                title: "Paste",
                action: #selector(pasteFromPasteboard),
                input: "v",
                modifierFlags: .command
            ),
            UIKeyCommand(
                title: "Scroll Up",
                action: #selector(scrollPageUp),
                input: UIKeyCommand.inputUpArrow,
                modifierFlags: .command
            ),
            UIKeyCommand(
                title: "Scroll Down",
                action: #selector(scrollPageDown),
                input: UIKeyCommand.inputDownArrow,
                modifierFlags: .command
            ),
        ]
    }

    @objc func copySelection() {
        guard let text = selectedText() else { return }
        UIPasteboard.general.string = text
        clearSelection()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    @objc private func pasteFromPasteboard() {
        guard let text = UIPasteboard.general.string else { return }
        onPaste?(text)
    }

    @objc private func scrollPageUp() { onScroll?(max(1, lastReportedGrid.rows - 2)) }
    @objc private func scrollPageDown() { onScroll?(-max(1, lastReportedGrid.rows - 2)) }

    // MARK: - Gestures

    private func installGestures() {
        // A single tap focuses and raises the keyboard, which is the only way to type on
        // a phone.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        // Without this the single tap fires first and swallows the second, so
        // double-tap-to-select would never trigger.
        tap.require(toFail: doubleTap)

        // Two-finger pan scrolls the scrollback. One finger is reserved for selection, so
        // the two gestures cannot fight.
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        addGestureRecognizer(pan)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
        longPress.minimumPressDuration = 0.35
        addGestureRecognizer(longPress)
    }

    @objc private func handleTap() {
        // A tap with a selection showing dismisses it rather than raising the keyboard —
        // otherwise the only way out of a selection is to make another one.
        if renderView.selection != nil {
            clearSelection()
            return
        }
        if !isFirstResponder { _ = becomeFirstResponder() }
    }

    /// Double-tap selects the whole logical line, following soft wraps — the line a
    /// person sees, not the row the terminal happened to break it into.
    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard let screen = currentScreen?(),
              let position = renderView.position(at: recognizer.location(in: renderView)),
              let range = screen.logicalLineRange(containing: position.row)
        else { return }
        setSelection(range)
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func setSelection(_ range: TerminalRange?) {
        renderView.selection = range
        onSelectionChange?(range)
    }

    func clearSelection() {
        setSelection(nil)
    }

    /// The selected text, ready for the pasteboard.
    func selectedText() -> String? {
        guard let selection = renderView.selection, let screen = currentScreen?() else { return nil }
        let text = screen.text(in: selection)
        return text.isEmpty ? nil : text
    }

    private var panAccumulator: CGFloat = 0

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            panAccumulator = 0
        case .changed:
            let translation = recognizer.translation(in: self).y
            recognizer.setTranslation(.zero, in: self)
            panAccumulator += translation
            let rows = Int(panAccumulator / renderView.metrics.cellHeight)
            if rows != 0 {
                panAccumulator -= CGFloat(rows) * renderView.metrics.cellHeight
                onScroll?(rows)
            }
        default:
            panAccumulator = 0
        }
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard let position = renderView.position(at: recognizer.location(in: renderView)) else { return }
        switch recognizer.state {
        case .began:
            selectionAnchor = position
            setSelection(TerminalRange(start: position, end: position))
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .changed:
            guard let anchor = selectionAnchor else { return }
            setSelection(TerminalRange(start: anchor, end: position))
        case .ended:
            selectionAnchor = nil
            onSelectionChange?(renderView.selection)
        case .cancelled, .failed:
            selectionAnchor = nil
        default:
            break
        }
    }

    // MARK: - Sending

    private func send(_ data: Data) {
        onInput?(data)
    }

    /// Sends a control character for the accessory key row.
    func sendControl(_ character: Character) {
        guard let scalar = character.unicodeScalars.first,
              let byte = Self.controlByte(for: scalar) else { return }
        send(Data([byte]))
    }

    func sendNamedKey(_ key: AccessoryKey) {
        switch key {
        case .escape: send(Data([0x1B]))
        case .tab: send(Data([0x09]))
        case .up: send(cursorKey("A"))
        case .down: send(cursorKey("B"))
        case .left: send(cursorKey("D"))
        case .right: send(cursorKey("C"))
        case .home: send(cursorKey("H"))
        case .end: send(cursorKey("F"))
        case .pageUp: send(Data("\u{1B}[5~".utf8))
        case .pageDown: send(Data("\u{1B}[6~".utf8))
        }
    }
}

/// Keys offered on the on-screen accessory row.
enum AccessoryKey: String, CaseIterable, Identifiable {
    case escape, tab, up, down, left, right, home, end, pageUp, pageDown

    var id: String { rawValue }

    var label: String {
        switch self {
        case .escape: "esc"
        case .tab: "tab"
        case .up: "↑"
        case .down: "↓"
        case .left: "←"
        case .right: "→"
        case .home: "home"
        case .end: "end"
        case .pageUp: "pgup"
        case .pageDown: "pgdn"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .escape: "Escape"
        case .tab: "Tab"
        case .up: "Up arrow"
        case .down: "Down arrow"
        case .left: "Left arrow"
        case .right: "Right arrow"
        case .home: "Home"
        case .end: "End"
        case .pageUp: "Page up"
        case .pageDown: "Page down"
        }
    }
}
