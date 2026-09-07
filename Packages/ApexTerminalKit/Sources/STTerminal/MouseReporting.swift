import Foundation

/// A pointer event the terminal may need to report to the remote program.
public struct TerminalMouseEvent: Sendable, Equatable {
    public enum Button: Sendable, Equatable {
        case left
        case middle
        case right
        case scrollUp
        case scrollDown
        /// Motion with no button held. Only reported in "any event" mode.
        case none
    }

    public enum Action: Sendable, Equatable {
        case press
        case release
        case drag
        case motion
    }

    /// Zero-based grid coordinates.
    public var column: Int
    public var row: Int
    public var button: Button
    public var action: Action
    public var shift = false
    public var alt = false
    public var control = false

    public init(
        column: Int,
        row: Int,
        button: Button,
        action: Action,
        shift: Bool = false,
        alt: Bool = false,
        control: Bool = false
    ) {
        self.column = column
        self.row = row
        self.button = button
        self.action = action
        self.shift = shift
        self.alt = alt
        self.control = control
    }
}

/// Encodes pointer events in the form the remote program asked for.
///
/// Which encoding to use is not a preference — it is dictated by the modes the program
/// set. Getting it wrong is worse than sending nothing: a program expecting SGR that
/// receives the legacy form reads the bytes as keystrokes and scrambles its own state.
public enum MouseReportEncoder {
    /// Returns the bytes to send, or `nil` when this event should not be reported.
    ///
    /// - Parameters:
    ///   - event: the pointer event, in zero-based grid coordinates.
    ///   - modes: the modes the remote program has set.
    public static func encode(_ event: TerminalMouseEvent, modes: TerminalModes) -> Data? {
        guard modes.mouseTracking != .off else { return nil }

        switch event.action {
        case .press, .release:
            break
        case .drag:
            // Drag is only reported from button-event tracking upwards.
            guard modes.mouseTracking == .buttonEvent || modes.mouseTracking == .anyEvent else { return nil }
        case .motion:
            guard modes.mouseTracking == .anyEvent else { return nil }
        }

        let code = buttonCode(for: event)
        return modes.sgrMouseEncoding
            ? encodeSGR(event, code: code)
            : encodeLegacy(event, code: code)
    }

    /// The button field, before the encoding-specific offset.
    ///
    /// Layout is from xterm's `ctlseqs`: low two bits are the button, bit 2 shift, bit 3
    /// meta, bit 4 control, bit 5 motion, and bit 6 marks the wheel.
    static func buttonCode(for event: TerminalMouseEvent) -> Int {
        var code: Int
        switch event.button {
        case .left: code = 0
        case .middle: code = 1
        case .right: code = 2
        case .none: code = 3
        case .scrollUp: code = 64
        case .scrollDown: code = 65
        }

        // In the legacy encoding a release does not say which button was let go, so it is
        // reported as button 3. SGR keeps the button and marks the release with `m`.
        if event.action == .release, event.button != .scrollUp, event.button != .scrollDown {
            code = 3
        }
        if event.action == .drag || event.action == .motion {
            code += 32
        }
        if event.shift { code += 4 }
        if event.alt { code += 8 }
        if event.control { code += 16 }
        return code
    }

    static func encodeSGR(_ event: TerminalMouseEvent, code: Int) -> Data {
        // SGR keeps the real button on release and has no coordinate ceiling, which is
        // why it is the only correct encoding past column 223.
        var sgrCode = code
        if event.action == .release, event.button != .scrollUp, event.button != .scrollDown {
            sgrCode = buttonCodePreservingButton(event)
        }
        let terminator = event.action == .release ? "m" : "M"
        return Data("\u{1B}[<\(sgrCode);\(event.column + 1);\(event.row + 1)\(terminator)".utf8)
    }

    private static func buttonCodePreservingButton(_ event: TerminalMouseEvent) -> Int {
        var code: Int
        switch event.button {
        case .left: code = 0
        case .middle: code = 1
        case .right: code = 2
        case .none: code = 3
        case .scrollUp: code = 64
        case .scrollDown: code = 65
        }
        if event.shift { code += 4 }
        if event.alt { code += 8 }
        if event.control { code += 16 }
        return code
    }

    static func encodeLegacy(_ event: TerminalMouseEvent, code: Int) -> Data? {
        // The legacy encoding adds 32 to every field so the bytes stay printable, which
        // caps coordinates at 223. Beyond that there is no representable value, and
        // sending a wrapped one would report a click somewhere the user did not touch —
        // so nothing is sent and the program simply sees no event.
        let column = event.column + 1
        let row = event.row + 1
        guard column <= 223, row <= 223 else { return nil }

        var bytes = Array("\u{1B}[M".utf8)
        bytes.append(UInt8(clamping: code + 32))
        bytes.append(UInt8(clamping: column + 32))
        bytes.append(UInt8(clamping: row + 32))
        return Data(bytes)
    }
}
