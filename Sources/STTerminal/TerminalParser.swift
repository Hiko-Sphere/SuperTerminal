import Foundation

/// Actions a ``TerminalParser`` emits. The parser knows nothing about screens; it turns
/// a byte stream into structured terminal operations, and a separate emulator applies
/// them. Keeping the two apart is what makes the parser exhaustively testable against
/// published conformance cases without a screen model in the way.
public enum TerminalAction: Sendable, Equatable {
    /// A printable grapheme cluster, already decoded and width-measured.
    case print(Character)
    /// A C0 or C1 control character.
    case execute(UInt8)
    /// A CSI sequence: `ESC [ params intermediates final`.
    case csi(CSISequence)
    /// An escape sequence with no CSI: `ESC intermediates final`.
    case escape(intermediates: [UInt8], final: UInt8)
    /// A completed OSC string: `ESC ] ... ST`.
    case osc(command: Int, payload: String)
    /// A completed DCS string.
    case dcs(DCSSequence)
}

/// A parsed CSI sequence.
public struct CSISequence: Sendable, Equatable {
    /// Numeric parameters. An omitted parameter is represented as `nil` so that
    /// "default" and "explicitly zero" stay distinguishable — several sequences treat
    /// them differently.
    public let parameters: [Int?]
    /// Sub-parameters, as introduced by `:` (used by SGR for direct colour).
    public let subParameters: [[Int?]]
    /// A private-marker byte such as `?` in `CSI ? 25 h`.
    public let privateMarker: UInt8?
    public let intermediates: [UInt8]
    public let final: UInt8

    public init(
        parameters: [Int?],
        subParameters: [[Int?]] = [],
        privateMarker: UInt8? = nil,
        intermediates: [UInt8] = [],
        final: UInt8
    ) {
        self.parameters = parameters
        self.subParameters = subParameters
        self.privateMarker = privateMarker
        self.intermediates = intermediates
        self.final = final
    }

    /// Parameter at `index`, or `default` when absent or omitted.
    public func parameter(_ index: Int, default defaultValue: Int) -> Int {
        guard index < parameters.count, let value = parameters[index] else { return defaultValue }
        return value
    }
}

public struct DCSSequence: Sendable, Equatable {
    public let parameters: [Int?]
    public let intermediates: [UInt8]
    public let final: UInt8
    public let payload: String
}

/// A byte-stream parser for ANSI/VT escape sequences.
///
/// The state machine follows the structure Paul Williams derived from the DEC VT500
/// hardware — the same shape used by xterm and by every terminal that behaves correctly
/// on malformed input. Its important property is that *no* byte sequence can wedge it:
/// every state has a defined transition for every byte, so a hostile or corrupt stream
/// degrades to visible garbage rather than to a hang, an over-read, or unbounded growth.
///
/// UTF-8 decoding sits in front of the state machine, and combining marks are joined
/// into grapheme clusters, so `print` always carries something displayable in one cell
/// run.
public struct TerminalParser: Sendable {
    /// Hard caps. A stream that exceeds them is truncated rather than buffered, which is
    /// what stops `printf '\e]0;%s' $(yes | head -c 100M)` from exhausting memory.
    public static let maximumStringLength = 8192
    public static let maximumParameters = 32
    public static let maximumIntermediates = 4

    enum State: Sendable {
        case ground
        case escape
        case escapeIntermediate
        case csiEntry
        case csiParam
        case csiIntermediate
        case csiIgnore
        case dcsEntry
        case dcsParam
        case dcsIntermediate
        case dcsPassthrough
        case dcsIgnore
        case oscString
        case sosPmApcString
    }

    private var state: State = .ground
    private var parameters: [Int?] = []
    private var subParameters: [[Int?]] = []
    private var currentSubParameters: [Int?] = []
    private var currentParameter: Int?
    private var privateMarker: UInt8?
    private var intermediates: [UInt8] = []
    private var stringBuffer: String = ""
    private var stringTruncated = false
    private var utf8Decoder = UTF8Accumulator()
    /// Holds a base character while we wait to see whether the next scalar combines
    /// with it, so `e` + U+0301 is delivered as one `Character`.
    private var pendingCharacter: Character?

    public init() {}

    /// Feeds bytes to the parser, calling `sink` for each action in order.
    public mutating func parse(_ bytes: some Sequence<UInt8>, sink: (TerminalAction) -> Void) {
        for byte in bytes {
            step(byte, sink: sink)
        }
    }

    /// Flushes any character held back waiting for a possible combining mark. Call this
    /// when a read burst ends so the last glyph is not delayed until more input arrives.
    public mutating func flush(sink: (TerminalAction) -> Void) {
        if let pending = pendingCharacter {
            pendingCharacter = nil
            sink(.print(pending))
        }
    }

    private mutating func step(_ byte: UInt8, sink: (TerminalAction) -> Void) {
        // C0 controls and ESC are handled identically from almost every state, which is
        // what lets a terminal recover from a truncated sequence.
        if byte == 0x1B {
            emitPending(sink: sink)
            // ESC while a string is being collected is the first half of ST (`ESC \\`).
            // The string ends here; the escape state then consumes the terminator.
            switch state {
            case .oscString: dispatchOSC(sink: sink)
            case .dcsPassthrough: dispatchDCS(sink: sink)
            case .dcsIgnore, .sosPmApcString: state = .ground
            default: break
            }
            enterEscape()
            return
        }
        if byte == 0x18 || byte == 0x1A {
            // CAN and SUB abort the current sequence and are executed.
            emitPending(sink: sink)
            state = .ground
            sink(.execute(byte))
            return
        }

        switch state {
        case .ground:
            ground(byte, sink: sink)
        case .escape:
            escape(byte, sink: sink)
        case .escapeIntermediate:
            escapeIntermediate(byte, sink: sink)
        case .csiEntry:
            csiEntry(byte, sink: sink)
        case .csiParam:
            csiParam(byte, sink: sink)
        case .csiIntermediate:
            csiIntermediate(byte, sink: sink)
        case .csiIgnore:
            csiIgnore(byte)
        case .dcsEntry:
            dcsEntry(byte)
        case .dcsParam:
            dcsParam(byte)
        case .dcsIntermediate:
            dcsIntermediate(byte)
        case .dcsPassthrough:
            dcsPassthrough(byte, sink: sink)
        case .dcsIgnore:
            dcsIgnore(byte)
        case .oscString:
            oscString(byte, sink: sink)
        case .sosPmApcString:
            sosPmApcString(byte)
        }
    }

    // MARK: - States

    private mutating func ground(_ byte: UInt8, sink: (TerminalAction) -> Void) {
        if byte < 0x20 || byte == 0x7F {
            emitPending(sink: sink)
            sink(.execute(byte))
            return
        }
        for scalar in utf8Decoder.consume(byte) {
            appendPrintable(scalar, sink: sink)
        }
    }

    private mutating func appendPrintable(_ scalar: Unicode.Scalar, sink: (TerminalAction) -> Void) {
        guard let pending = pendingCharacter else {
            pendingCharacter = Character(String(scalar))
            return
        }
        // Grow the held cluster if the new scalar attaches to it — that is how `e` plus
        // U+0301 becomes one `Character` occupying one cell. Otherwise the held cluster
        // is complete and can be emitted.
        var candidate = String(pending)
        candidate.unicodeScalars.append(scalar)
        if candidate.count == 1 {
            pendingCharacter = Character(candidate)
        } else {
            sink(.print(pending))
            pendingCharacter = Character(String(scalar))
        }
    }

    private mutating func emitPending(sink: (TerminalAction) -> Void) {
        guard let pending = pendingCharacter else { return }
        pendingCharacter = nil
        sink(.print(pending))
    }

    private mutating func enterEscape() {
        state = .escape
        clear()
    }

    private mutating func escape(_ byte: UInt8, sink: (TerminalAction) -> Void) {
        switch byte {
        case 0x00 ... 0x17, 0x19, 0x1C ... 0x1F:
            sink(.execute(byte))
        case 0x20 ... 0x2F:
            appendIntermediate(byte)
            state = .escapeIntermediate
        case 0x50: // P — DCS
            clear()
            state = .dcsEntry
        case 0x58, 0x5E, 0x5F: // X (SOS), ^ (PM), _ (APC)
            state = .sosPmApcString
        case 0x5B: // [ — CSI
            clear()
            state = .csiEntry
        case 0x5D: // ] — OSC
            stringBuffer = ""
            stringTruncated = false
            state = .oscString
        case 0x30 ... 0x4F, 0x51 ... 0x57, 0x59, 0x5A, 0x5C, 0x60 ... 0x7E:
            sink(.escape(intermediates: intermediates, final: byte))
            state = .ground
        case 0x7F:
            break // DEL is ignored
        default:
            state = .ground
        }
    }

    private mutating func escapeIntermediate(_ byte: UInt8, sink: (TerminalAction) -> Void) {
        switch byte {
        case 0x00 ... 0x17, 0x19, 0x1C ... 0x1F:
            sink(.execute(byte))
        case 0x20 ... 0x2F:
            appendIntermediate(byte)
        case 0x30 ... 0x7E:
            sink(.escape(intermediates: intermediates, final: byte))
            state = .ground
        default:
            state = .ground
        }
    }

    private mutating func csiEntry(_ byte: UInt8, sink: (TerminalAction) -> Void) {
        switch byte {
        case 0x00 ... 0x17, 0x19, 0x1C ... 0x1F:
            sink(.execute(byte))
        case 0x20 ... 0x2F:
            appendIntermediate(byte)
            state = .csiIntermediate
        case 0x30 ... 0x39, 0x3B, 0x3A:
            csiParam(byte, sink: sink)
            state = .csiParam
        case 0x3C ... 0x3F:
            privateMarker = byte
            state = .csiParam
        case 0x40 ... 0x7E:
            dispatchCSI(final: byte, sink: sink)
        default:
            state = .csiIgnore
        }
    }

    private mutating func csiParam(_ byte: UInt8, sink: (TerminalAction) -> Void) {
        switch byte {
        case 0x00 ... 0x17, 0x19, 0x1C ... 0x1F:
            sink(.execute(byte))
        case 0x30 ... 0x39:
            let digit = Int(byte - 0x30)
            // Saturate rather than overflow: `CSI 99999999999999999999 H` must not trap.
            let existing = currentParameter ?? 0
            currentParameter = existing > 65535 ? 65535 : existing * 10 + digit
        case 0x3A:
            currentSubParameters.append(currentParameter)
            currentParameter = nil
        case 0x3B:
            finishParameter()
        case 0x20 ... 0x2F:
            appendIntermediate(byte)
            state = .csiIntermediate
        case 0x40 ... 0x7E:
            dispatchCSI(final: byte, sink: sink)
        default:
            state = .csiIgnore
        }
    }

    private mutating func csiIntermediate(_ byte: UInt8, sink: (TerminalAction) -> Void) {
        switch byte {
        case 0x00 ... 0x17, 0x19, 0x1C ... 0x1F:
            sink(.execute(byte))
        case 0x20 ... 0x2F:
            appendIntermediate(byte)
        case 0x40 ... 0x7E:
            dispatchCSI(final: byte, sink: sink)
        default:
            state = .csiIgnore
        }
    }

    private mutating func csiIgnore(_ byte: UInt8) {
        if (0x40 ... 0x7E).contains(byte) { state = .ground }
    }

    private mutating func dcsEntry(_ byte: UInt8) {
        switch byte {
        case 0x20 ... 0x2F:
            appendIntermediate(byte)
            state = .dcsIntermediate
        case 0x30 ... 0x39, 0x3B:
            dcsParam(byte)
            state = .dcsParam
        case 0x3C ... 0x3F:
            privateMarker = byte
            state = .dcsParam
        case 0x40 ... 0x7E:
            finishParameter()
            intermediates.append(byte)
            stringBuffer = ""
            stringTruncated = false
            state = .dcsPassthrough
        default:
            state = .dcsIgnore
        }
    }

    private mutating func dcsParam(_ byte: UInt8) {
        switch byte {
        case 0x30 ... 0x39:
            let existing = currentParameter ?? 0
            currentParameter = existing > 65535 ? 65535 : existing * 10 + Int(byte - 0x30)
        case 0x3B:
            finishParameter()
        case 0x20 ... 0x2F:
            appendIntermediate(byte)
            state = .dcsIntermediate
        case 0x40 ... 0x7E:
            finishParameter()
            intermediates.append(byte)
            stringBuffer = ""
            stringTruncated = false
            state = .dcsPassthrough
        default:
            state = .dcsIgnore
        }
    }

    private mutating func dcsIntermediate(_ byte: UInt8) {
        switch byte {
        case 0x20 ... 0x2F:
            appendIntermediate(byte)
        case 0x40 ... 0x7E:
            intermediates.append(byte)
            stringBuffer = ""
            stringTruncated = false
            state = .dcsPassthrough
        default:
            state = .dcsIgnore
        }
    }

    private mutating func dcsPassthrough(_ byte: UInt8, sink: (TerminalAction) -> Void) {
        if byte == 0x9C {
            dispatchDCS(sink: sink)
            return
        }
        appendToString(byte)
    }

    private mutating func dcsIgnore(_ byte: UInt8) {
        if byte == 0x9C { state = .ground }
    }

    private mutating func oscString(_ byte: UInt8, sink: (TerminalAction) -> Void) {
        // BEL terminates an OSC in xterm's dialect; ST (ESC \) is the standard form and
        // is handled when ESC is seen.
        if byte == 0x07 || byte == 0x9C {
            dispatchOSC(sink: sink)
            return
        }
        appendToString(byte)
    }

    private mutating func sosPmApcString(_ byte: UInt8) {
        if byte == 0x9C { state = .ground }
    }

    // MARK: - Dispatch

    private mutating func dispatchCSI(final: UInt8, sink: (TerminalAction) -> Void) {
        finishParameter()
        sink(.csi(CSISequence(
            parameters: parameters,
            subParameters: subParameters,
            privateMarker: privateMarker,
            intermediates: intermediates,
            final: final
        )))
        state = .ground
        clear()
    }

    private mutating func dispatchOSC(sink: (TerminalAction) -> Void) {
        defer {
            state = .ground
            stringBuffer = ""
            stringTruncated = false
        }
        guard !stringTruncated else { return }
        let parts = stringBuffer.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first, let command = Int(first) else { return }
        let payload = parts.count > 1 ? String(parts[1]) : ""
        sink(.osc(command: command, payload: payload))
    }

    private mutating func dispatchDCS(sink: (TerminalAction) -> Void) {
        defer {
            state = .ground
            clear()
            stringBuffer = ""
            stringTruncated = false
        }
        guard let final = intermediates.last, !stringTruncated else { return }
        sink(.dcs(DCSSequence(
            parameters: parameters,
            intermediates: Array(intermediates.dropLast()),
            final: final,
            payload: stringBuffer
        )))
    }

    // MARK: - Helpers

    private mutating func clear() {
        parameters = []
        subParameters = []
        currentSubParameters = []
        currentParameter = nil
        privateMarker = nil
        intermediates = []
    }

    private mutating func finishParameter() {
        guard parameters.count < Self.maximumParameters else { return }
        parameters.append(currentParameter)
        subParameters.append(currentSubParameters)
        currentParameter = nil
        currentSubParameters = []
    }

    private mutating func appendIntermediate(_ byte: UInt8) {
        guard intermediates.count < Self.maximumIntermediates else { return }
        intermediates.append(byte)
    }

    private mutating func appendToString(_ byte: UInt8) {
        guard stringBuffer.utf8.count < Self.maximumStringLength else {
            stringTruncated = true
            return
        }
        for scalar in utf8Decoder.consume(byte) {
            stringBuffer.unicodeScalars.append(scalar)
        }
    }
}

/// Incremental UTF-8 decoder.
///
/// Invalid sequences produce U+FFFD and resynchronise on the next lead byte, matching
/// what terminals do: a corrupt byte must not swallow the text that follows it.
struct UTF8Accumulator: Sendable {
    static let replacement = Unicode.Scalar(0xFFFD)!

    private var buffer: [UInt8] = []
    private var expected = 0

    /// Returns the scalars completed by this byte — usually zero or one, but two when a
    /// truncated sequence is terminated by the lead byte of the next character, which is
    /// why this returns an array rather than an optional.
    mutating func consume(_ byte: UInt8) -> [Unicode.Scalar] {
        if expected == 0 {
            return startSequence(byte)
        }

        guard byte & 0xC0 == 0x80 else {
            // Not a continuation byte: the sequence in progress was truncated. Report a
            // replacement for it, then process this byte as a fresh lead so the text
            // that follows a corrupt byte is not swallowed with it.
            buffer = []
            expected = 0
            return [Self.replacement] + startSequence(byte)
        }

        buffer.append(byte)
        expected -= 1
        guard expected == 0 else { return [] }

        var iterator = buffer.makeIterator()
        var decoder = UTF8()
        buffer = []
        if case let .scalarValue(scalar) = decoder.decode(&iterator) {
            return [scalar]
        }
        return [Self.replacement]
    }

    private mutating func startSequence(_ byte: UInt8) -> [Unicode.Scalar] {
        switch byte {
        case 0x00 ... 0x7F:
            return [Unicode.Scalar(byte)]
        case 0xC2 ... 0xDF:
            expected = 1
        case 0xE0 ... 0xEF:
            expected = 2
        case 0xF0 ... 0xF4:
            expected = 3
        default:
            return [Self.replacement]
        }
        buffer = [byte]
        return []
    }
}
