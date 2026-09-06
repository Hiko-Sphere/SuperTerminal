import STVNC
import SwiftUI
import UIKit

/// The remote screen and everything that drives it (D-022): a zoomable image of the
/// framebuffer, touch gestures that become pointer events, the on-screen keyboard,
/// hardware keys, and a mouse or trackpad on iPad.
///
/// Touch: a tap clicks, a drag moves the pointer, touch-and-hold then drag drags with the
/// button held, two fingers tapped is a right click, two fingers moved is the scroll
/// wheel, a pinch zooms. Once zoomed, two fingers pan the view instead and the wheel comes
/// back at fit-to-screen — the two cannot share a gesture, and panning what you zoomed
/// into is what two fingers mean everywhere else on the platform.
///
/// Pointer: the local pointer is hidden over the screen so the remote cursor is the only
/// one; clicks, drags, secondary and middle buttons and the wheel go through as they are.
/// The click recognisers take pointer touches only, for the reason D-018 records.
final class VNCScreenUIView: UIView, UIKeyInput, UIScrollViewDelegate, UIPointerInteractionDelegate {
    /// Pointer moved or a button changed: framebuffer x, y and the RFB button mask.
    var onPointer: ((Int, Int, UInt8) -> Void)?
    /// Wheel steps at a framebuffer point: vertical (positive down), horizontal (positive right).
    var onWheel: ((Int, Int, Int, Int) -> Void)?
    /// A key went down or up, as an X11 keysym.
    var onKey: ((UInt32, Bool) -> Void)?
    /// Text from the on-screen keyboard.
    var onText: ((String) -> Void)?
    var onHaptic: ((Haptics.Event) -> Void)?

    /// Whether ⌘ combinations go to the remote as Super, or stay with the app.
    var sendsCommandKey = false
    /// Whether the on-screen keyboard should be up.
    ///
    /// Separate from holding first-responder status, which the screen does whenever it is
    /// showing so that a hardware keyboard reaches the remote without anything being
    /// tapped first. Before, the two were the same switch: an external keyboard did
    /// nothing until you asked for the on-screen one, which then covered the screen.
    var showsSoftwareKeyboard = false {
        didSet {
            guard showsSoftwareKeyboard != oldValue, isFirstResponder else { return }
            reloadInputViews()
        }
    }

    let contentView = VNCContentView()
    private let scrollView = UIScrollView()

    private(set) var framebufferSize = CGSize.zero
    private var desktopName = ""
    /// Buttons currently held, as the RFB mask.
    private var buttonMask: UInt8 = 0
    /// Where the pointer last was, in framebuffer pixels; wheel events go there.
    private var lastPointer = (x: 0, y: 0)
    /// Movement waiting to become whole wheel steps, per axis.
    ///
    /// It survives between gestures for the reason D-025 records: iPadOS delivers one
    /// mouse-wheel notch as an entire gesture — `.began` then `.ended`, with no
    /// `.changed` — and a notch is shorter than a step, so a handler that read only
    /// `.changed`, or that threw away its remainder whenever a gesture began, could never
    /// reach a step at all. The wheel did nothing while a trackpad worked.
    private var wheelVertical = ScrollAccumulator()
    private var wheelHorizontal = ScrollAccumulator()
    /// Points of travel per wheel step.
    private static let wheelStep: CGFloat = 24

    private var twoFingerPan: UIPanGestureRecognizer!

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        installScrollView()
        installTouchGestures()
        installPointerTracking()
        isAccessibilityElement = true
        accessibilityTraits = .image
        accessibilityIdentifier = "vnc-screen"
        accessibilityLabel = String(localized: "Remote screen")
        accessibilityHint = String(localized: "Tap to click. Touch and hold to drag. Two fingers scroll or, when zoomed, pan.")
        updateAccessibilityValue()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // MARK: - State from the session

    func update(framebufferSize: CGSize, desktopName: String) {
        let changed = framebufferSize != self.framebufferSize || desktopName != self.desktopName
        self.framebufferSize = framebufferSize
        self.desktopName = desktopName
        if changed { updateAccessibilityValue() }
    }

    private func updateAccessibilityValue() {
        let size = "\(Int(framebufferSize.width)) × \(Int(framebufferSize.height))"
        accessibilityValue = desktopName.isEmpty ? size : "\(desktopName), \(size)"
    }

    /// Back to fit-to-screen, from the menu.
    func resetZoom() {
        scrollView.setZoomScale(1, animated: true)
    }

    // MARK: - Layout

    private func installScrollView() {
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.bouncesZoom = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        // One finger is the pointer; the view itself pans with two, and only once zoomed.
        scrollView.panGestureRecognizer.minimumNumberOfTouches = 2
        scrollView.panGestureRecognizer.isEnabled = false
        scrollView.backgroundColor = .black
        addSubview(scrollView)
        contentView.isMultipleTouchEnabled = true
        contentView.isUserInteractionEnabled = true
        scrollView.addSubview(contentView)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        if scrollView.zoomScale == 1 {
            scrollView.contentSize = bounds.size
            contentView.frame = CGRect(origin: .zero, size: bounds.size)
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { contentView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        let zoomed = scrollView.zoomScale > 1.01
        scrollView.panGestureRecognizer.isEnabled = zoomed
        twoFingerPan.isEnabled = !zoomed
    }

    /// Where the framebuffer is drawn inside the content view: aspect-fit, centred.
    func imageRect() -> CGRect {
        guard framebufferSize.width > 0, framebufferSize.height > 0 else { return .zero }
        let bounds = contentView.bounds
        let scale = min(bounds.width / framebufferSize.width, bounds.height / framebufferSize.height)
        let size = CGSize(width: framebufferSize.width * scale, height: framebufferSize.height * scale)
        return CGRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    /// The framebuffer pixel under a point in the content view, clamped to the screen so
    /// its edges stay reachable.
    func framebufferPoint(for point: CGPoint) -> (x: Int, y: Int)? {
        let rect = imageRect()
        guard rect.width > 0, rect.height > 0 else { return nil }
        let x = (point.x - rect.minX) / rect.width * framebufferSize.width
        let y = (point.y - rect.minY) / rect.height * framebufferSize.height
        return (
            Int(min(max(x, 0), framebufferSize.width - 1)),
            Int(min(max(y, 0), framebufferSize.height - 1))
        )
    }

    // MARK: - Sending

    private func move(to point: CGPoint, mask: UInt8? = nil) {
        guard let target = framebufferPoint(for: point) else { return }
        if let mask { buttonMask = mask }
        lastPointer = target
        onPointer?(target.x, target.y, buttonMask)
    }

    private func click(at point: CGPoint, button: VNCSession.Button) {
        guard let target = framebufferPoint(for: point) else { return }
        lastPointer = target
        onPointer?(target.x, target.y, buttonMask | button.rawValue)
        onPointer?(target.x, target.y, buttonMask)
    }

    private func wheel(by translation: CGPoint, at point: CGPoint) {
        let vertical = wheelVertical.consume(translation: translation.y, cellHeight: Self.wheelStep)
        let horizontal = wheelHorizontal.consume(translation: translation.x, cellHeight: Self.wheelStep)
        guard vertical != 0 || horizontal != 0 else { return }
        let target = framebufferPoint(for: point) ?? lastPointer
        // Fingers moving down means the content should move down, which is the wheel
        // scrolling up — the same inversion every touch surface makes.
        onWheel?(target.x, target.y, -vertical, -horizontal)
    }

    #if DEBUG
    /// The wheel path without a gesture recogniser, which no test can drive on iOS.
    func reportWheelForTesting(translation: CGPoint, at point: CGPoint) {
        wheel(by: translation, at: point)
    }
    #endif

    private func resetWheel() {
        wheelVertical.reset()
        wheelHorizontal.reset()
    }

    // MARK: - Touch

    private func installTouchGestures() {
        let direct = [NSNumber(value: UITouch.TouchType.direct.rawValue)]

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.numberOfTouchesRequired = 1
        contentView.addGestureRecognizer(tap)

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.allowedTouchTypes = direct
        contentView.addGestureRecognizer(twoFingerTap)

        // Touch and hold takes the button down; movement afterwards is a drag with it
        // held, and lifting releases. The long press keeps reporting position changes, so
        // no second recogniser is needed — and none can start once this one has.
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleHold(_:)))
        hold.minimumPressDuration = 0.4
        hold.allowableMovement = .greatestFiniteMagnitude
        hold.allowedTouchTypes = direct
        contentView.addGestureRecognizer(hold)

        // One finger moving is the pointer moving: what a hover does with a mouse.
        let fingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleFingerPan(_:)))
        fingerPan.minimumNumberOfTouches = 1
        fingerPan.maximumNumberOfTouches = 1
        fingerPan.allowedTouchTypes = direct
        fingerPan.allowedScrollTypesMask = []
        contentView.addGestureRecognizer(fingerPan)

        twoFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        twoFingerPan.allowedTouchTypes = direct
        twoFingerPan.allowedScrollTypesMask = []
        contentView.addGestureRecognizer(twoFingerPan)
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: contentView)
        // A tap with a finger moves the pointer there first, so the remote sees the
        // motion a real pointer would have made; a mouse click has already hovered.
        move(to: point)
        click(at: point, button: .left)
        onHaptic?(.selectionChanged)
    }

    @objc private func handleTwoFingerTap(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: contentView)
        move(to: point)
        click(at: point, button: .right)
        onHaptic?(.selectionChanged)
    }

    @objc private func handleHold(_ recognizer: UILongPressGestureRecognizer) {
        let point = recognizer.location(in: contentView)
        switch recognizer.state {
        case .began:
            move(to: point, mask: buttonMask | VNCSession.Button.left.rawValue)
            onHaptic?(.modifierArmed)
        case .changed:
            move(to: point)
        case .ended, .cancelled, .failed:
            move(to: point, mask: buttonMask & ~VNCSession.Button.left.rawValue)
        default:
            break
        }
    }

    @objc private func handleFingerPan(_ recognizer: UIPanGestureRecognizer) {
        guard recognizer.state == .changed || recognizer.state == .began else { return }
        move(to: recognizer.location(in: contentView))
    }

    @objc private func handleTwoFingerPan(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed, .ended:
            let translation = recognizer.translation(in: contentView)
            guard translation != .zero else { return }
            recognizer.setTranslation(.zero, in: contentView)
            wheel(by: translation, at: recognizer.location(in: contentView))
        default:
            resetWheel()
        }
    }

    // MARK: - Pointer

    private func installPointerTracking() {
        let pointerOnly = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        contentView.addGestureRecognizer(hover)

        // Click-drag: button down where the drag starts, held while it moves.
        let drag = UIPanGestureRecognizer(target: self, action: #selector(handlePointerDrag(_:)))
        drag.allowedTouchTypes = pointerOnly
        drag.allowedScrollTypesMask = []
        drag.minimumNumberOfTouches = 1
        drag.maximumNumberOfTouches = 1
        contentView.addGestureRecognizer(drag)

        // Scroll events arrive with no touches, so this recogniser takes none.
        let wheel = UIPanGestureRecognizer(target: self, action: #selector(handleWheel(_:)))
        wheel.allowedScrollTypesMask = .all
        wheel.allowedTouchTypes = []
        contentView.addGestureRecognizer(wheel)

        let secondary = UITapGestureRecognizer(target: self, action: #selector(handleSecondaryClick(_:)))
        secondary.buttonMaskRequired = .secondary
        secondary.allowedTouchTypes = pointerOnly
        contentView.addGestureRecognizer(secondary)

        let middle = UITapGestureRecognizer(target: self, action: #selector(handleMiddleClick(_:)))
        middle.buttonMaskRequired = .button(3)
        middle.allowedTouchTypes = pointerOnly
        contentView.addGestureRecognizer(middle)

        contentView.addInteraction(UIPointerInteraction(delegate: self))
    }

    /// The remote draws its own cursor; two would be one too many.
    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        .hidden()
    }

    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        guard recognizer.state == .began || recognizer.state == .changed else { return }
        move(to: recognizer.location(in: contentView))
    }

    @objc private func handlePointerDrag(_ recognizer: UIPanGestureRecognizer) {
        let point = recognizer.location(in: contentView)
        switch recognizer.state {
        case .began:
            // Where the button went down, not where the pan was recognised: a pan begins
            // only once the pointer has moved past its slop, and pressing at the later
            // point drags a window (or a selection) from the wrong place.
            let origin = CGPoint(
                x: point.x - recognizer.translation(in: contentView).x,
                y: point.y - recognizer.translation(in: contentView).y
            )
            move(to: origin, mask: buttonMask | VNCSession.Button.left.rawValue)
            move(to: point)
        case .changed:
            move(to: point)
        case .ended, .cancelled, .failed:
            move(to: point, mask: buttonMask & ~VNCSession.Button.left.rawValue)
        default:
            break
        }
    }

    @objc private func handleWheel(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed, .ended:
            let translation = recognizer.translation(in: contentView)
            guard translation != .zero else { return }
            recognizer.setTranslation(.zero, in: contentView)
            // A wheel's translation already points the way the content should move.
            wheel(by: translation, at: recognizer.location(in: contentView))
        default:
            resetWheel()
        }
    }

    @objc private func handleSecondaryClick(_ recognizer: UITapGestureRecognizer) {
        click(at: recognizer.location(in: contentView), button: .right)
    }

    @objc private func handleMiddleClick(_ recognizer: UITapGestureRecognizer) {
        click(at: recognizer.location(in: contentView), button: .middle)
    }

    // MARK: - Keyboard

    override var canBecomeFirstResponder: Bool { true }

    /// A zero-height input view keeps the on-screen keyboard down while the responder
    /// chain still delivers hardware keys and `insertText`. Returning `nil` would let
    /// UIKit put the system keyboard up over half the remote screen.
    override var inputView: UIView? {
        showsSoftwareKeyboard ? nil : Self.emptyKeyboard
    }

    private static let emptyKeyboard: UIView = {
        let view = UIView(frame: .zero)
        view.autoresizingMask = .flexibleWidth
        return view
    }()

    var hasText: Bool { true }

    func insertText(_ text: String) {
        onText?(text)
    }

    func deleteBackward() {
        onKey?(VNCKeysym.backspace, true)
        onKey?(VNCKeysym.backspace, false)
    }

    var keyboardType: UIKeyboardType { get { .default } set {} }
    var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
    var smartQuotesType: UITextSmartQuotesType { get { .no } set {} }
    var smartDashesType: UITextSmartDashesType { get { .no } set {} }
    var smartInsertDeleteType: UITextSmartInsertDeleteType { get { .no } set {} }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = handle(presses, down: true)
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = handle(presses, down: false)
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = handle(presses, down: false)
        if !unhandled.isEmpty { super.pressesCancelled(unhandled, with: event) }
    }

    /// Sends what is the remote's and returns the rest for the system.
    private func handle(_ presses: Set<UIPress>, down: Bool) -> Set<UIPress> {
        var unhandled: Set<UIPress> = []
        for press in presses {
            guard let key = press.key,
                  let keysym = VNCKeyMap.keysym(
                      keyCode: key.keyCode,
                      characters: key.characters,
                      charactersIgnoringModifiers: key.charactersIgnoringModifiers,
                      modifiers: key.modifierFlags,
                      sendsCommandKey: sendsCommandKey
                  )
            else {
                unhandled.insert(press)
                continue
            }
            onKey?(keysym, down)
        }
        return unhandled
    }
}

/// Draws the framebuffer image, aspect-fit. A layer with contents, nothing more: the
/// image is already in the display's pixel format.
final class VNCContentView: UIView {
    var image: CGImage? {
        didSet { layer.contents = image }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        layer.contentsGravity = .resizeAspect
        layer.magnificationFilter = .linear
        layer.minificationFilter = .trilinear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

/// Hardware keys to X11 keysyms. Pure, so it can be tested without a `UIKey`.
enum VNCKeyMap {
    /// `nil` means the key is not the remote's: ⌘ combinations stay with the app unless
    /// the user asked for ⌘ to be sent, and keys with no character and no name fall
    /// through to the system.
    static func keysym(
        keyCode: UIKeyboardHIDUsage,
        characters: String,
        charactersIgnoringModifiers: String,
        modifiers: UIKeyModifierFlags,
        sendsCommandKey: Bool
    ) -> UInt32? {
        if modifiers.contains(.command), !sendsCommandKey,
           keyCode != .keyboardLeftGUI, keyCode != .keyboardRightGUI {
            return nil
        }
        switch keyCode {
        case .keyboardReturnOrEnter, .keypadEnter: return VNCKeysym.return
        case .keyboardEscape: return VNCKeysym.escape
        case .keyboardDeleteOrBackspace: return VNCKeysym.backspace
        case .keyboardDeleteForward: return VNCKeysym.delete
        case .keyboardTab: return VNCKeysym.tab
        case .keyboardLeftArrow: return VNCKeysym.left
        case .keyboardRightArrow: return VNCKeysym.right
        case .keyboardUpArrow: return VNCKeysym.up
        case .keyboardDownArrow: return VNCKeysym.down
        case .keyboardHome: return VNCKeysym.home
        case .keyboardEnd: return VNCKeysym.end
        case .keyboardPageUp: return VNCKeysym.pageUp
        case .keyboardPageDown: return VNCKeysym.pageDown
        case .keyboardInsert: return VNCKeysym.insert
        case .keyboardCapsLock: return VNCKeysym.capsLock
        case .keyboardLeftShift, .keyboardRightShift: return VNCKeysym.shiftLeft
        case .keyboardLeftControl, .keyboardRightControl: return VNCKeysym.controlLeft
        case .keyboardLeftAlt, .keyboardRightAlt: return VNCKeysym.altLeft
        case .keyboardLeftGUI, .keyboardRightGUI: return sendsCommandKey ? VNCKeysym.superLeft : nil
        case .keyboardF1: return VNCKeysym.function(1)
        case .keyboardF2: return VNCKeysym.function(2)
        case .keyboardF3: return VNCKeysym.function(3)
        case .keyboardF4: return VNCKeysym.function(4)
        case .keyboardF5: return VNCKeysym.function(5)
        case .keyboardF6: return VNCKeysym.function(6)
        case .keyboardF7: return VNCKeysym.function(7)
        case .keyboardF8: return VNCKeysym.function(8)
        case .keyboardF9: return VNCKeysym.function(9)
        case .keyboardF10: return VNCKeysym.function(10)
        case .keyboardF11: return VNCKeysym.function(11)
        case .keyboardF12: return VNCKeysym.function(12)
        case .keyboardSpacebar: return 0x20
        default:
            // With Control or Option held the characters are control codes or dead-key
            // output; the remote wants the key underneath, with the modifier it already
            // received. Shift is different: "A" is its own keysym.
            let source = modifiers.contains(.control) || modifiers.contains(.alternate) || modifiers.contains(.command)
                ? charactersIgnoringModifiers
                : characters
            guard let scalar = source.unicodeScalars.first else { return nil }
            if scalar.value < 0x20, let raw = charactersIgnoringModifiers.unicodeScalars.first, raw.value >= 0x20 {
                return VNCKeysym.forCharacter(raw)
            }
            guard scalar.value >= 0x20 else { return nil }
            return VNCKeysym.forCharacter(scalar)
        }
    }
}

/// Hosts the screen in SwiftUI and wires input back to the session.
struct VNCScreenView: UIViewRepresentable {
    let session: VNCSession
    let image: CGImage?
    let desktopSize: CGSize
    let desktopName: String
    /// Whether the on-screen keyboard should be up. The screen holds the keyboard either
    /// way, so a hardware keyboard always reaches the remote (D-029).
    let showsSoftwareKeyboard: Bool
    /// Whether this screen is the one on show and nothing is covering it.
    let wantsKeyboard: Bool
    /// Bumped from the menu to return to fit-to-screen.
    let zoomResetToken: Int
    let onHaptic: (Haptics.Event) -> Void

    func makeUIView(context: Context) -> VNCScreenUIView {
        let view = VNCScreenUIView()
        view.onPointer = { x, y, mask in
            Task { @MainActor in session.pointer(x: x, y: y, buttons: mask) }
        }
        view.onWheel = { x, y, vertical, horizontal in
            Task { @MainActor in session.wheel(x: x, y: y, vertical: vertical, horizontal: horizontal) }
        }
        view.onKey = { keysym, down in
            Task { @MainActor in session.key(keysym, down: down) }
        }
        view.onText = { text in
            Task { @MainActor in session.type(text) }
        }
        view.onHaptic = { event in
            Task { @MainActor in onHaptic(event) }
        }
        return view
    }

    func updateUIView(_ view: VNCScreenUIView, context: Context) {
        view.contentView.image = image
        view.update(framebufferSize: desktopSize, desktopName: desktopName)
        view.sendsCommandKey = session.sendsCommandKey
        view.showsSoftwareKeyboard = showsSoftwareKeyboard
        if wantsKeyboard, !view.isFirstResponder, view.window != nil {
            _ = view.becomeFirstResponder()
        } else if !wantsKeyboard, view.isFirstResponder {
            _ = view.resignFirstResponder()
        }
        if context.coordinator.zoomResetToken != zoomResetToken {
            context.coordinator.zoomResetToken = zoomResetToken
            view.resetZoom()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var zoomResetToken = 0
    }
}
