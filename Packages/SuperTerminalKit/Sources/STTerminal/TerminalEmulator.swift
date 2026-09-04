import Foundation

/// Terminal modes a remote program can turn on and off, and which the UI must honour.
public struct TerminalModes: Sendable, Equatable {
    /// DECCKM. Arrow keys send `SS3` instead of `CSI` — full-screen editors rely on it.
    public var applicationCursorKeys = false
    /// DECNKM / keypad application mode.
    public var applicationKeypad = false
    /// DECAWM. Off means long lines are truncated at the margin rather than wrapped.
    public var autoWrap = true
    /// DECOM. Cursor addressing is relative to the scroll region.
    public var originMode = false
    /// IRM. Printing inserts rather than overwrites.
    public var insertMode = false
    /// DECTCEM.
    public var cursorVisible = true
    /// Bracketed paste: pasted text is wrapped in `ESC [ 200 ~` … `ESC [ 201 ~`, which
    /// is what lets a shell tell typed input from pasted input and refuse to run it.
    public var bracketedPaste = false
    /// Mouse reporting level requested by the program.
    public var mouseTracking: MouseTracking = .off
    /// SGR-encoded mouse coordinates (1006), which are the only ones correct past
    /// column 223.
    public var sgrMouseEncoding = false
    /// Whether the alternate screen buffer is in use.
    public var alternateScreen = false
    /// Reverse video for the whole screen (DECSCNM).
    public var reverseVideo = false

    public enum MouseTracking: Sendable, Equatable {
        case off
        /// Press and release only (1000).
        case click
        /// Click plus drag (1002).
        case buttonEvent
        /// Every motion (1003).
        case anyEvent
    }

    public init() {}
}

/// A hyperlink declared with OSC 8.
public struct TerminalHyperlink: Sendable, Equatable {
    public let id: String?
    public let url: String
}

/// Things the emulator needs the host application to do.
public enum TerminalEvent: Sendable, Equatable {
    /// The program set the window or icon title.
    case title(String)
    /// The program rang the bell.
    case bell
    /// Bytes that must be written back to the remote host — cursor position reports,
    /// device attributes and similar. A terminal that does not answer these makes
    /// programs that query it hang.
    case respond(Data)
    /// The program switched buffers; the UI should stop offering scrollback.
    case alternateScreenChanged(Bool)
    /// A mode the UI must react to changed (mouse reporting, bracketed paste, …).
    case modesChanged(TerminalModes)
}

/// Applies parsed terminal actions to a screen.
///
/// The emulator owns two screens — primary and alternate — and switches between them
/// rather than saving and restoring one, which is what makes leaving `vim` restore the
/// shell output underneath exactly as it was.
public struct TerminalEmulator: Sendable {
    // These are `internal(set)` rather than `private(set)` because the emulator's
    // behaviour is split across focused extensions in this module — CSI, SGR, screen
    // management — and each needs to mutate the same state. Nothing outside the module
    // can write to them.
    public internal(set) var screen: TerminalScreen
    public internal(set) var alternateScreen: TerminalScreen
    public internal(set) var modes = TerminalModes()
    public internal(set) var title = ""
    public internal(set) var hyperlinks: [Int: TerminalHyperlink] = [:]

    var parser = TerminalParser()
    var savedCursor: TerminalCursor?
    var savedAttributes: CellAttributes?
    var tabStops: Set<Int>
    var nextHyperlinkID = 1
    var currentHyperlinkID: Int?

    /// The maximum answer-back burst produced by one write. A program that spams
    /// position queries cannot be allowed to make the client generate unbounded output.
    public static let maximumPendingResponseBytes = 64 * 1024

    public init(columns: Int, rows: Int, scrollbackLimit: Int = 10000) {
        screen = TerminalScreen(columns: columns, rows: rows, scrollbackLimit: scrollbackLimit)
        // The alternate screen never contributes to history: that is the whole point of
        // it, and it is why leaving a full-screen program does not leave its redraws
        // behind in the scrollback.
        alternateScreen = TerminalScreen(columns: columns, rows: rows, scrollbackLimit: 0)
        tabStops = Set(stride(from: 8, to: max(columns, 8), by: 8))
    }

    /// The screen currently being drawn to.
    public var activeScreen: TerminalScreen {
        modes.alternateScreen ? alternateScreen : screen
    }

    /// Feeds bytes from the remote host and returns the events the UI must act on.
    public mutating func feed(_ bytes: some Sequence<UInt8>) -> [TerminalEvent] {
        var events: [TerminalEvent] = []
        var responseBytes = 0
        // The parser is moved into a local for the duration of the pass. It is a member,
        // and the sink below mutates `self`, so parsing in place would be overlapping
        // exclusive access to the same value.
        var activeParser = parser
        activeParser.parse(bytes) { action in
            apply(action) { event in
                if case let .respond(data) = event {
                    guard responseBytes + data.count <= Self.maximumPendingResponseBytes else { return }
                    responseBytes += data.count
                }
                events.append(event)
            }
        }
        parser = activeParser
        return events
    }

    /// Flushes a grapheme cluster held back while waiting for a possible combining mark.
    public mutating func flush() -> [TerminalEvent] {
        var events: [TerminalEvent] = []
        var activeParser = parser
        activeParser.flush { action in apply(action) { events.append($0) } }
        parser = activeParser
        return events
    }

    public mutating func resize(columns: Int, rows: Int) {
        screen.resize(columns: columns, rows: rows)
        alternateScreen.resize(columns: columns, rows: rows)
        tabStops = Set(stride(from: 8, to: max(columns, 8), by: 8))
    }

    // MARK: - Action dispatch

    mutating func apply(_ action: TerminalAction, emit: (TerminalEvent) -> Void) {
        switch action {
        case let .print(character):
            withActiveScreen { screen, modes in
                if modes.insertMode { screen.insertCharacters(CharacterWidth.of(character)) }
                if !modes.autoWrap, screen.pendingWrap { return }
                screen.write(character)
            }
        case let .execute(byte):
            execute(byte, emit: emit)
        case let .csi(sequence):
            applyCSI(sequence, emit: emit)
        case let .escape(intermediates, final):
            applyEscape(intermediates: intermediates, final: final, emit: emit)
        case let .osc(command, payload):
            applyOSC(command: command, payload: payload, emit: emit)
        case .dcs:
            // DCS carries device-control strings such as Sixel graphics and terminfo
            // queries. Nothing here uses them yet, and silently discarding is the
            // correct behaviour for a terminal that does not implement them.
            break
        }
    }

    mutating func withActiveScreen(_ body: (inout TerminalScreen, TerminalModes) -> Void) {
        if modes.alternateScreen {
            body(&alternateScreen, modes)
        } else {
            body(&screen, modes)
        }
    }

    mutating func execute(_ byte: UInt8, emit: (TerminalEvent) -> Void) {
        switch byte {
        case 0x07:
            emit(.bell)
        case 0x08: // BS
            withActiveScreen { screen, _ in
                if screen.pendingWrap {
                    screen.pendingWrap = false
                } else if screen.cursor.column > 0 {
                    screen.cursor.column -= 1
                }
            }
        case 0x09: // HT
            tabForward()
        case 0x0A, 0x0B, 0x0C: // LF, VT, FF
            withActiveScreen { screen, _ in screen.lineFeed() }
        case 0x0D: // CR
            withActiveScreen { screen, _ in screen.carriageReturn() }
        default:
            break
        }
    }

    mutating func applyEscape(intermediates: [UInt8], final: UInt8, emit: (TerminalEvent) -> Void) {
        guard intermediates.isEmpty else {
            // Character-set designators such as `ESC ( B`. Only the default set is
            // supported; the alternatives select legacy line-drawing fonts that modern
            // programs reach through Unicode instead.
            return
        }
        switch final {
        case 0x37: // 7 — DECSC
            saveCursorState()
        case 0x38: // 8 — DECRC
            restoreCursorState()
        case 0x44: // D — IND
            withActiveScreen { screen, _ in screen.lineFeed() }
        case 0x45: // E — NEL
            withActiveScreen { screen, _ in
                screen.carriageReturn()
                screen.lineFeed()
            }
        case 0x4D: // M — RI
            withActiveScreen { screen, _ in screen.reverseLineFeed() }
        case 0x48: // H — HTS
            tabStops.insert(activeScreen.cursor.column)

        case 0x63: // c — RIS
            reset(emit: emit)
        case 0x3D: // = — keypad application mode
            modes.applicationKeypad = true
            emit(.modesChanged(modes))
        case 0x3E: // > — keypad numeric mode
            modes.applicationKeypad = false
            emit(.modesChanged(modes))
        default:
            break
        }
    }

    mutating func reset(emit: (TerminalEvent) -> Void) {
        let columns = screen.columns
        let rows = screen.rows
        let limit = screen.scrollbackLimit
        screen = TerminalScreen(columns: columns, rows: rows, scrollbackLimit: limit)
        alternateScreen = TerminalScreen(columns: columns, rows: rows, scrollbackLimit: 0)
        modes = TerminalModes()
        tabStops = Set(stride(from: 8, to: max(columns, 8), by: 8))
        savedCursor = nil
        savedAttributes = nil
        currentHyperlinkID = nil
        title = ""
        emit(.modesChanged(modes))
        emit(.alternateScreenChanged(false))
    }
}
