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
    /// Columns, rows, and the same in pixels — the last two because a program that draws
    /// pictures has no other way to know how big a cell is (D-065).
    var onGridSizeChange: ((Int, Int, Int, Int) -> Void)?
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
    override func validate(_ command: UICommand) {
        if let shortcut = AppShortcut(command: command) {
            command.attributes = (shortcutRouter?.isAvailable(shortcut) ?? false) ? [] : .disabled
        }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(performAppShortcut(_:)):
            return shortcutRouter != nil
        case #selector(copySelection), #selector(copy(_:)):
            return renderView.selection != nil
        case #selector(paste(_:)):
            return UIPasteboard.general.hasStrings
        case #selector(selectAll(_:)):
            return renderView.lastRow != nil
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
        // The pixel size is the grid's, not the view's: a few points of slack at the right
        // and bottom belong to no cell, and a program dividing the picture area by the
        // number of columns must get the cell size back (D-065).
        let metrics = renderView.metrics
        onGridSizeChange?(
            grid.columns,
            grid.rows,
            Int(metrics.cellWidth) * grid.columns,
            Int(metrics.cellHeight) * grid.rows
        )
    }

    // MARK: - Input method composition (D-039)

    /// What an input method is still assembling. Empty whenever nothing is being composed,
    /// which is every keystroke in English.
    var composition = TerminalComposition()
    /// Held weakly by UIKit's contract; it is the system's object, not ours.
    weak var textInputDelegate: UITextInputDelegate?
    lazy var compositionTokenizer: UITextInputTokenizer = UITextInputStringTokenizer(textInput: self)

    /// Sends whatever the input method has committed and clears the buffer.
    func commitComposition() {
        let committed = composition.take()
        refreshComposition()
        guard !committed.isEmpty else { return }
        send(Data(committed.utf8))
    }

    /// Tells the renderer what to draw under the cursor, and the system that the document
    /// changed so the candidate list can follow the caret.
    func refreshComposition() {
        renderView.composition = composition.text
    }

    /// Where the caret sits, in this view's coordinates, `offset` characters into the
    /// composition. The candidate list positions itself against this.
    func compositionCaretRect(atCharacterOffset offset: Int) -> CGRect {
        guard let cell = compositionOriginAndCellWidth() else { return .zero }
        return CGRect(
            x: cell.origin.x + CGFloat(offset) * cell.width,
            y: cell.origin.y,
            width: 2,
            height: cell.height
        )
    }

    /// The cursor cell's origin and the cell size, or nil before the first frame arrives.
    func compositionOriginAndCellWidth() -> (origin: CGPoint, width: CGFloat, height: CGFloat)? {
        renderView.cursorOriginForComposition()
    }

    // MARK: - UIKeyInput

    var hasText: Bool { !composition.isEmpty }

    /// The software keyboard sends text through here, one insertion at a time. An input
    /// method that has finished composing also arrives here, so anything still marked is
    /// committed first — otherwise the composition would be sent after the text that
    /// replaced it.
    func insertText(_ text: String) {
        if !composition.isEmpty {
            composition = TerminalComposition()
            refreshComposition()
        }
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
        // While an input method is composing, backspace belongs to the composition: it
        // removes a syllable from the buffer rather than a character from the shell, which
        // is not looking at the buffer at all.
        if composition.deleteBackward() {
            refreshComposition()
            return
        }
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

    /// Maps a hardware key press to the bytes a terminal expects; see `HardwareKeyMap`.
    ///
    /// Returns `nil` for keys that should fall through to the system — so ⌘C still copies
    /// and ⌘K still reaches the app's own shortcuts, rather than being swallowed and sent
    /// to the remote host as gibberish.
    func encode(_ key: UIKey) -> Data? {
        HardwareKeyMap.encode(
            keyCode: key.keyCode,
            characters: key.characters,
            charactersIgnoringModifiers: key.charactersIgnoringModifiers,
            modifiers: key.modifierFlags,
            applicationCursorKeys: modes.applicationCursorKeys
        )
    }

    static func controlByte(for scalar: Unicode.Scalar) -> UInt8? { HardwareKeyMap.controlByte(for: scalar) }

    /// Arrow and Home/End keys change encoding when the program sets application cursor
    /// mode; used by the on-screen key row, which has no `UIKey` to map.
    private func cursorKey(_ letter: String) -> Data {
        Data((modes.applicationCursorKeys ? "\u{1B}O\(letter)" : "\u{1B}[\(letter)").utf8)
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
                title: String(localized: "Find"),
                action: #selector(findInScrollback),
                input: "f",
                modifierFlags: .command
            ),
            UIKeyCommand(
                title: String(localized: "Select All"),
                action: #selector(selectAll(_:)),
                input: "a",
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
        ] + AppShortcut.keyCommands(action: #selector(performAppShortcut(_:)))
    }

    /// The app-level shortcuts, routed to the container's router; the terminal is first
    /// responder whenever it is on screen, so they have to be reachable from here too.
    var shortcutRouter: AppShortcutRouter?

    @objc func performAppShortcut(_ sender: UIKeyCommand) {
        guard let shortcut = AppShortcut(command: sender) else { return }
        shortcutRouter?.perform(shortcut)
    }

    /// Declared here as well as in the app's menu because this view is first responder
    /// whenever a terminal is on screen, and a key command declared only on the scene is
    /// not reached while a responder below it is consuming key presses.
    @objc func showCommandPalette() {
        onCommandPalette?()
    }

    /// Set by the SwiftUI wrapper: search belongs to the session view, the key belongs here.
    var onFind: (() -> Void)?

    @objc func findInScrollback() {
        onFind?()
    }

    // MARK: - Standard edit actions

    /// The edit menu a secondary click shows is built from these, so they are the
    /// standard selectors rather than this view's own.
    override func copy(_ sender: Any?) { copySelection() }
    override func paste(_ sender: Any?) { pasteFromPasteboard() }
    override func selectAll(_ sender: Any?) {
        guard let last = renderView.lastRow, lastReportedGrid.columns > 0 else { return }
        setSelection(TerminalRange(
            start: TerminalPosition(row: 0, column: 0),
            end: TerminalPosition(row: last, column: lastReportedGrid.columns - 1)
        ))
        onSelectionChange?(renderView.selection)
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
        // Off until something is selected. A pointer begins a drag lift on click-and-drag
        // with no long press, and the lift fails every competing recogniser — including
        // the pan that makes a selection — so an always-on drag interaction means a mouse
        // can never select anything. The delegate would refuse the drag a moment later,
        // but by then the selection gesture is gone.
        drag.isEnabled = false
        addInteraction(drag)
        dragInteraction = drag
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
        // Only a selection is draggable, so the interaction exists only while one does.
        dragInteraction?.isEnabled = range != nil
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

    /// Scrolling, from two fingers on the glass and from a wheel or trackpad.
    ///
    /// Every state that can carry a translation is consumed, and the accumulator survives
    /// between gestures. A wheel is why: iPadOS delivers one notch as a whole gesture —
    /// `.began` and then `.ended`, with no `.changed` at all — so reading only `.changed`
    /// made a mouse wheel do nothing while a trackpad worked, and zeroing the accumulator
    /// per gesture would have thrown away every notch smaller than one cell, which is most
    /// of them. Only a cancelled or failed gesture discards what it had accumulated.
    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed, .ended:
            consumeScroll(from: recognizer)
        default:
            scroll.reset()
        }
    }

    private func consumeScroll(from recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: self).y
        guard translation != 0 else { return }
        recognizer.setTranslation(.zero, in: self)
        let rows = scroll.consume(translation: translation, cellHeight: renderView.metrics.cellHeight)
        guard rows != 0 else { return }

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
    private var editMenu: UIEditMenuInteraction?
    private var scroll = ScrollAccumulator()
    private var dragInteraction: UIDragInteraction?
    private var pointerDragAnchor: TerminalPosition?

    private func installPointerTracking() {
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        addGestureRecognizer(hover)

        // Scroll wheel and trackpad scrolling. Scroll events arrive with no touches, so
        // this recogniser takes none — the two-finger pan above keeps direct touches, and
        // the two cannot fight over a click-drag.
        let wheel = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        wheel.allowedScrollTypesMask = .all
        wheel.allowedTouchTypes = []
        addGestureRecognizer(wheel)

        // Click-drag with a mouse or trackpad selects text; a program tracking the mouse
        // gets the drag instead, which is how a tmux pane is resized with a pointer.
        let drag = UIPanGestureRecognizer(target: self, action: #selector(handlePointerDrag(_:)))
        drag.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        drag.allowedScrollTypesMask = []
        drag.minimumNumberOfTouches = 1
        drag.maximumNumberOfTouches = 1
        addGestureRecognizer(drag)

        // Secondary click: the remote program's if it is tracking the mouse, otherwise the
        // edit menu — the same contract as every text surface on iPadOS.
        //
        // Both click recognisers take pointer touches only. A button mask alone is not a
        // pointer check: a synthesised direct tap satisfied `.button(3)`, and every
        // live-terminal UI test that tapped the terminal then pasted whatever the previous
        // test had copied — the prompt's own glyphs, which the shell tried to run.
        let pointerOnly = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        let secondary = UITapGestureRecognizer(target: self, action: #selector(handleSecondaryClick(_:)))
        secondary.buttonMaskRequired = .secondary
        secondary.allowedTouchTypes = pointerOnly
        addGestureRecognizer(secondary)

        // Middle click pastes, as it has on every X11 terminal; a tracking program gets it.
        let middle = UITapGestureRecognizer(target: self, action: #selector(handleMiddleClick(_:)))
        middle.buttonMaskRequired = .button(3)
        middle.allowedTouchTypes = pointerOnly
        addGestureRecognizer(middle)

        let menu = UIEditMenuInteraction(delegate: nil)
        addInteraction(menu)
        editMenu = menu
        addInteraction(UIPointerInteraction(delegate: self))
    }

    @objc private func handlePointerDrag(_ recognizer: UIPanGestureRecognizer) {
        guard let position = renderView.position(at: recognizer.location(in: renderView)) else { return }
        switch recognizer.state {
        case .began:
            // Where the button went down, not where the recogniser recognised: a pan only
            // begins once the pointer has moved past its slop, which at this cell size is
            // a character or two — enough to lose the first letter of every selection.
            let origin = CGPoint(
                x: recognizer.location(in: renderView).x - recognizer.translation(in: renderView).x,
                y: recognizer.location(in: renderView).y - recognizer.translation(in: renderView).y
            )
            let position = renderView.position(at: origin) ?? position
            if modes.mouseTracking != .off {
                reportMouse(at: position, button: .left, action: .press)
                pointerDragAnchor = position
                return
            }
            pointerDragAnchor = position
            setSelection(TerminalRange(start: position, end: position))
        case .changed:
            guard let anchor = pointerDragAnchor else { return }
            if modes.mouseTracking != .off {
                reportMouse(at: position, button: .left, action: .drag)
                return
            }
            setSelection(TerminalRange(start: anchor, end: position))
        case .ended:
            if modes.mouseTracking != .off {
                reportMouse(at: position, button: .left, action: .release)
            } else {
                onSelectionChange?(renderView.selection)
            }
            pointerDragAnchor = nil
        case .cancelled, .failed:
            pointerDragAnchor = nil
        default:
            break
        }
    }

    @objc private func handleSecondaryClick(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: self)
        if modes.mouseTracking != .off, let position = renderView.position(at: recognizer.location(in: renderView)) {
            reportMouse(at: position, button: .right, action: .press)
            reportMouse(at: position, button: .right, action: .release)
            return
        }
        if !isFirstResponder { _ = becomeFirstResponder() }
        editMenu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
    }

    @objc private func handleMiddleClick(_ recognizer: UITapGestureRecognizer) {
        if modes.mouseTracking != .off, let position = renderView.position(at: recognizer.location(in: renderView)) {
            reportMouse(at: position, button: .middle, action: .press)
            reportMouse(at: position, button: .middle, action: .release)
            return
        }
        pasteFromPasteboard()
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

// MARK: - Pointer style

extension TerminalInputView: UIPointerInteractionDelegate {
    /// A text surface shows a beam, sized to a cell so it reads as "here is where the
    /// character goes" rather than as a generic cursor.
    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        UIPointerStyle(shape: .verticalBeam(length: renderView.metrics.cellHeight))
    }
}
