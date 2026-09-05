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
    /// Called with a pointer event the remote program asked to be told about.
    var onMouseEvent: ((TerminalMouseEvent) -> Void)?
    /// Called when the user taps a cell carrying an OSC 8 hyperlink.
    var onHyperlinkTapped: ((TerminalPosition) -> Void)?
    /// Called when a pinch changes the requested font size, in points.
    var onFontSizeChange: ((CGFloat) -> Void)?
    /// Called when the user asks for the command palette.
    var onCommandPalette: (() -> Void)?
    /// Plays a haptic. Supplied rather than reached for, so this view does not decide
    /// whether the user wants haptics at all.
    var onHaptic: ((Haptics.Event) -> Void)?
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
        installPointerTracking()
        installDragAndDrop()
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
        reportGridSizeIfChanged()
    }

    /// Re-measures the grid and tells the session if it changed.
    ///
    /// Called on layout *and* whenever the font changes: a pinch changes the size of a
    /// cell without changing the view's bounds, so `layoutSubviews` never runs and the
    /// remote program would go on believing it has the old number of columns. Every line
    /// it wraps would then wrap in the wrong place.
    func reportGridSizeIfChanged() {
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
                title: String(localized: "Command Palette"),
                action: #selector(showCommandPalette),
                input: "k",
                modifierFlags: .command
            ),
            UIKeyCommand(
                title: String(localized: "Copy"),
                action: #selector(copySelection),
                input: "c",
                modifierFlags: .command
            ),
            UIKeyCommand(
                title: String(localized: "Paste"),
                action: #selector(pasteFromPasteboard),
                input: "v",
                modifierFlags: .command
            ),
            UIKeyCommand(
                title: String(localized: "Scroll Up"),
                action: #selector(scrollPageUp),
                input: UIKeyCommand.inputUpArrow,
                modifierFlags: .command
            ),
            UIKeyCommand(
                title: String(localized: "Scroll Down"),
                action: #selector(scrollPageDown),
                input: UIKeyCommand.inputDownArrow,
                modifierFlags: .command
            ),
        ]
    }

    /// Declared here as well as in the app's menu because this view is first responder
    /// whenever a terminal is on screen, and a key command declared only on the scene is
    /// not reached while a responder below it is consuming key presses.
    @objc func showCommandPalette() {
        onCommandPalette?()
    }

    /// Set by the SwiftUI wrapper so the copy honours the clipboard-expiry setting; the
    /// view has no access to settings and must not guess a default.
    var onCopy: ((String) -> Void)?

    @objc func copySelection() {
        guard let text = selectedText() else { return }
        if let onCopy {
            onCopy(text)
        } else {
            UIPasteboard.general.string = text
        }
        clearSelection()
        onHaptic?(.textInserted)
    }

    @objc private func pasteFromPasteboard() {
        guard let text = UIPasteboard.general.string else { return }
        onPaste?(text)
    }

    @objc private func scrollPageUp() { onScroll?(max(1, lastReportedGrid.rows - 2)) }
    @objc private func scrollPageDown() { onScroll?(-max(1, lastReportedGrid.rows - 2)) }

    // MARK: - Drag and drop

    /// Text can be dragged out of a selection, and dropped in from anywhere.
    ///
    /// On iPad this is how text moves between apps, and a terminal that does not take part
    /// is a terminal you have to copy and paste through. Both directions are wired to the
    /// same paths the existing gestures use, so a drop is a paste and a drag is a copy —
    /// including the confirmation a multi-line paste triggers. A drop that bypassed that
    /// would be a way to run several commands at once with one gesture and no warning.
    private func installDragAndDrop() {
        let drag = UIDragInteraction(delegate: self)
        drag.isEnabled = true
        addInteraction(drag)
        addInteraction(UIDropInteraction(delegate: self))
    }

    // MARK: - Gestures

    private func installGestures() {
        // A single tap focuses and raises the keyboard, which is the only way to type on
        // a phone.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
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

        // Pinch resizes the text, which on a phone is the difference between reading a
        // log and squinting at one. The grid is re-measured from the new metrics, so the
        // remote program is told the new geometry rather than being left to guess.
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
        longPress.minimumPressDuration = 0.35
        addGestureRecognizer(longPress)
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        // A tap with a selection showing dismisses it rather than raising the keyboard —
        // otherwise the only way out of a selection is to make another one.
        if renderView.selection != nil {
            clearSelection()
            return
        }

        let point = recognizer.location(in: renderView)
        if let position = renderView.position(at: point) {
            // A program tracking the mouse owns taps: this is how a pane is focused in
            // tmux or a line is clicked in a TUI file manager.
            if modes.mouseTracking != .off {
                if !isFirstResponder { _ = becomeFirstResponder() }
                reportMouse(at: position, button: .left, action: .press)
                reportMouse(at: position, button: .left, action: .release)
                return
            }
            onHyperlinkTapped?(position)
        }

        if !isFirstResponder { _ = becomeFirstResponder() }
    }

    private func reportMouse(
        at position: TerminalPosition,
        button: TerminalMouseEvent.Button,
        action: TerminalMouseEvent.Action
    ) {
        guard let screen = currentScreen?() else { return }
        // Mouse reports are in *screen* coordinates; the buffer's absolute row has to be
        // converted back, or a program would be told about a click on a row that scrolled
        // out of view.
        let screenRow = position.row - screen.scrollback.count + renderView.scrollbackOffset
        guard screenRow >= 0, screenRow < screen.rows else { return }
        onMouseEvent?(
            TerminalMouseEvent(
                column: position.column,
                row: screenRow,
                button: button,
                action: action
            )
        )
    }

    /// Double-tap selects the whole logical line, following soft wraps — the line a
    /// person sees, not the row the terminal happened to break it into.
    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard let screen = currentScreen?(),
              let position = renderView.position(at: recognizer.location(in: renderView)),
              let range = screen.logicalLineRange(containing: position.row)
        else { return }
        setSelection(range)
        onHaptic?(.selectionChanged)
    }

    func setSelection(_ range: TerminalRange?) {
        renderView.selection = range
        onSelectionChange?(range)
    }

    func clearSelection() {
        setSelection(nil)
    }

    /// The selected text, ready for the pasteboard.
    private var fontSizeAtPinchStart: CGFloat?

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            fontSizeAtPinchStart = renderView.fontSize
        case .changed:
            guard let start = fontSizeAtPinchStart else { return }
            let proposed = start * recognizer.scale
            let clamped = min(max(proposed, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
            // Rounded to whole points: the grid is measured in character cells, and a
            // fractional size makes every cell boundary land somewhere different.
            onFontSizeChange?(clamped.rounded())
        case .ended, .cancelled, .failed:
            fontSizeAtPinchStart = nil
        default:
            break
        }
    }

    /// Taken from the setting rather than declared again: the pinch and the stepper in
    /// Settings must not disagree about what sizes are allowed.
    static var fontSizeRange: ClosedRange<CGFloat> {
        CGFloat(AppSettings.fontSizeRange.lowerBound) ... CGFloat(AppSettings.fontSizeRange.upperBound)
    }

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
            guard rows != 0 else { return }
            panAccumulator -= CGFloat(rows) * renderView.metrics.cellHeight

            if modes.mouseTracking != .off {
                // A program tracking the mouse expects wheel events; scrolling our own
                // history instead would leave `less` and `htop` unable to scroll at all.
                let position = renderView.position(at: recognizer.location(in: renderView))
                    ?? TerminalPosition(row: 0, column: 0)
                let button: TerminalMouseEvent.Button = rows > 0 ? .scrollUp : .scrollDown
                for _ in 0 ..< min(abs(rows), 10) {
                    reportMouse(at: position, button: button, action: .press)
                }
                return
            }
            onScroll?(rows)
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
            onHaptic?(.modifierArmed)
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

    // MARK: - Pointer

    /// Reports trackpad and mouse movement on iPad when the program asked for it.
    ///
    /// Hover only matters in "any event" tracking — the mode a program sets when it wants
    /// to highlight what is under the pointer — so nothing is sent otherwise, and a
    /// trackpad user does not flood the connection with motion reports.
    private func installPointerTracking() {
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        addGestureRecognizer(hover)
    }

    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        guard modes.mouseTracking == .anyEvent else { return }
        guard recognizer.state == .changed || recognizer.state == .began else { return }
        guard let position = renderView.position(at: recognizer.location(in: renderView)) else { return }
        reportMouse(at: position, button: .none, action: .motion)
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

    /// What is printed on the key cap. Not translated: a keyboard reads the same in every
    /// language, and a row of translated caps would no longer match anyone's hardware.
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
        case .escape: String(localized: "Escape")
        case .tab: String(localized: "Tab")
        case .up: String(localized: "Up arrow")
        case .down: String(localized: "Down arrow")
        case .left: String(localized: "Left arrow")
        case .right: String(localized: "Right arrow")
        case .home: String(localized: "Home")
        case .end: String(localized: "End")
        case .pageUp: String(localized: "Page up")
        case .pageDown: String(localized: "Page down")
        }
    }
}


// MARK: - Dragging text out

extension TerminalInputView: UIDragInteractionDelegate {
    func dragInteraction(
        _ interaction: UIDragInteraction,
        itemsForBeginning session: any UIDragSession
    ) -> [UIDragItem] {
        // Only a selection is draggable. Without this, any press-and-move on the grid
        // would start a drag and there would be no way to select anything at all.
        guard let text = selectedText(), !text.isEmpty else { return [] }
        guard let selection = renderView.selection else { return [] }
        let point = session.location(in: self)
        guard let position = renderView.position(at: point), selection.contains(position) else { return [] }

        let provider = NSItemProvider(object: text as NSString)
        return [UIDragItem(itemProvider: provider)]
    }

    func dragInteraction(
        _ interaction: UIDragInteraction,
        previewForLifting item: UIDragItem,
        session: any UIDragSession
    ) -> UITargetedDragPreview? {
        guard let selection = renderView.selection else { return nil }
        let rect = renderView.boundingRect(of: selection)
        guard !rect.isNull, !rect.isEmpty else { return nil }

        // A snapshot of the selected cells, so what lifts off the screen is the text the
        // user is moving rather than an opaque rectangle.
        let renderer = UIGraphicsImageRenderer(bounds: rect)
        let image = renderer.image { context in
            context.cgContext.translateBy(x: -rect.minX, y: -rect.minY)
            renderView.draw(renderView.bounds)
        }
        let preview = UIImageView(image: image)
        preview.frame = CGRect(origin: .zero, size: rect.size)
        let target = UIDragPreviewTarget(container: self, center: CGPoint(x: rect.midX, y: rect.midY))
        return UITargetedDragPreview(view: preview, parameters: UIDragPreviewParameters(), target: target)
    }
}

// MARK: - Dropping text in

extension TerminalInputView: UIDropInteractionDelegate {
    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: any UIDropSession) -> Bool {
        session.canLoadObjects(ofClass: NSString.self)
    }

    func dropInteraction(
        _ interaction: UIDropInteraction,
        sessionDidUpdate session: any UIDropSession
    ) -> UIDropProposal {
        // Copy, never move: text dragged from another app should still be there
        // afterwards, and there is nothing in a terminal for a move to remove.
        UIDropProposal(operation: .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: any UIDropSession) {
        session.loadObjects(ofClass: NSString.self) { [weak self] items in
            guard let self else { return }
            let text = items.compactMap { $0 as? String }.joined()
            guard !text.isEmpty else { return }
            // The same path a paste takes, so a multi-line drop is confirmed exactly as a
            // multi-line paste is. Dropping past that check would turn one gesture into
            // several commands with no warning.
            onPaste?(text)
        }
    }
}
