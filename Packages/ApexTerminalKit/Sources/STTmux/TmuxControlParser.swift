import Foundation

/// Turns the bytes tmux writes in control mode into ``TmuxControlMessage`` values.
///
/// Incremental, because the bytes arrive from an SSH channel in whatever sizes the network
/// chose: a line can be split across three reads and two lines can arrive in one. The
/// parser holds the partial line and emits nothing until it has a whole one.
///
/// Lines rather than bytes is safe here, and that is a property of the protocol rather than
/// an assumption: everything tmux sends in a `%output` is escaped in octal, so a newline
/// inside a pane's output arrives as `\012` and cannot end a line by accident.
public struct TmuxControlParser: Sendable {
    /// Bytes seen since the last newline.
    private var partial: [UInt8] = []
    /// Whether the parser is between `%begin` and `%end`/`%error`, where every line is a
    /// command's reply rather than a notification — including a line that starts with `%`,
    /// which `list-panes` output does.
    private var insideCommand = false
    /// A hard ceiling on one line, so a server that never sends a newline cannot grow this
    /// without bound. tmux's own lines are short; a pane's output is escaped, so the worst
    /// case is four bytes per byte of output on a wide terminal.
    private static let maximumLineLength = 4 * 1024 * 1024

    public init() {}

    public enum ParseError: Error, Equatable {
        case lineTooLong(Int)
    }

    /// Feeds bytes in, and returns whatever complete messages they finished.
    public mutating func consume(_ bytes: some Sequence<UInt8>) throws -> [TmuxControlMessage] {
        var messages: [TmuxControlMessage] = []
        for byte in bytes {
            if byte == 0x0A {
                // A trailing carriage return is dropped: over a pseudo-terminal tmux's
                // lines end \r\n, over a pipe just \n, and the client should not care which
                // it got.
                if partial.last == 0x0D { partial.removeLast() }
                messages.append(parse(line: partial))
                partial.removeAll(keepingCapacity: true)
            } else {
                partial.append(byte)
                if partial.count > Self.maximumLineLength {
                    partial.removeAll(keepingCapacity: false)
                    throw ParseError.lineTooLong(Self.maximumLineLength)
                }
            }
        }
        return messages
    }

    private mutating func parse(line bytes: [UInt8]) -> TmuxControlMessage {
        // Only the framing is text; a pane's output is bytes and stays bytes. Decoding the
        // line as UTF-8 for dispatch is safe because the parts that matter — the leading
        // `%name` and the ids — are ASCII, and the payload is put back together from the
        // original bytes rather than from the decoded string.
        let line = String(decoding: bytes, as: UTF8.self)

        if insideCommand {
            if line.hasPrefix("%end ") || line.hasPrefix("%error ") {
                insideCommand = false
                let failed = line.hasPrefix("%error")
                let fields = line.split(separator: " ")
                let number = fields.count > 2 ? Int(fields[2]) ?? -1 : -1
                return .commandEnd(number: number, failed: failed)
            }
            return .commandOutput(line)
        }

        guard line.hasPrefix("%") else {
            // tmux does not send bare lines outside a command block. One means the far end
            // is not tmux at all — a shell profile printing a banner, most often — and the
            // caller needs to see it rather than have it swallowed.
            return .commandOutput(line)
        }

        if line.hasPrefix("%begin ") {
            insideCommand = true
            let fields = line.split(separator: " ")
            return .commandBegin(
                number: fields.count > 2 ? Int(fields[2]) ?? -1 : -1,
                time: fields.count > 1 ? Int(fields[1]) ?? 0 : 0,
                flags: fields.count > 3 ? Int(fields[3]) ?? 0 : 0
            )
        }

        let (name, rest) = Self.split(line: line)
        return .notification(notification(name: name, rest: rest, lineBytes: bytes))
    }

    /// `%name rest of the line` → (`name`, `rest of the line`).
    private static func split(line: String) -> (String, String) {
        let withoutSigil = line.dropFirst()
        guard let space = withoutSigil.firstIndex(of: " ") else { return (String(withoutSigil), "") }
        return (String(withoutSigil[..<space]), String(withoutSigil[withoutSigil.index(after: space)...]))
    }

    private func notification(name: String, rest: String, lineBytes: [UInt8]) -> TmuxNotification {
        switch name {
        case "output":
            guard let (pane, payloadOffset) = Self.paneAndOffset(rest: rest, lineBytes: lineBytes, name: name) else {
                return .unrecognised(name: name, arguments: rest)
            }
            return .output(pane: pane, bytes: Self.unescape(Array(lineBytes[payloadOffset...])))

        case "extended-output":
            // `%extended-output %0 1 : data` — the `:` is a literal field, not a separator
            // that can appear in the data, because the data begins after it.
            let fields = rest.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count >= 4, let pane = Self.paneID(String(fields[0])), let age = Int(fields[1]) else {
                return .unrecognised(name: name, arguments: rest)
            }
            let prefix = "%\(name) \(fields[0]) \(fields[1]) \(fields[2]) "
            let offset = min(prefix.utf8.count, lineBytes.count)
            return .extendedOutput(pane: pane, age: age, bytes: Self.unescape(Array(lineBytes[offset...])))

        case "window-add", "window-close", "unlinked-window-add", "unlinked-window-close":
            guard let window = Self.windowID(rest.trimmingCharacters(in: .whitespaces)) else {
                return .unrecognised(name: name, arguments: rest)
            }
            switch name {
            case "window-add": return .windowAdd(window: window)
            case "window-close": return .windowClose(window: window)
            case "unlinked-window-add": return .unlinkedWindowAdd(window: window)
            default: return .unlinkedWindowClose(window: window)
            }

        case "window-renamed", "unlinked-window-renamed":
            let fields = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, let window = Self.windowID(String(fields[0])) else {
                return .unrecognised(name: name, arguments: rest)
            }
            let renamed = String(fields[1])
            return name == "window-renamed"
                ? .windowRenamed(window: window, name: renamed)
                : .unlinkedWindowRenamed(window: window, name: renamed)

        case "window-pane-changed":
            let fields = rest.split(separator: " ")
            guard fields.count >= 2, let window = Self.windowID(String(fields[0])),
                  let pane = Self.paneID(String(fields[1]))
            else { return .unrecognised(name: name, arguments: rest) }
            return .windowPaneChanged(window: window, pane: pane)

        case "sessions-changed":
            return .sessionsChanged

        case "session-changed":
            let fields = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            guard let first = fields.first, let session = Self.sessionID(String(first)) else {
                return .unrecognised(name: name, arguments: rest)
            }
            return .sessionChanged(session: session, name: fields.count > 1 ? String(fields[1]) : "")

        case "session-renamed":
            return .sessionRenamed(name: rest)

        case "session-window-changed":
            let fields = rest.split(separator: " ")
            guard fields.count >= 2, let session = Self.sessionID(String(fields[0])),
                  let window = Self.windowID(String(fields[1]))
            else { return .unrecognised(name: name, arguments: rest) }
            return .sessionWindowChanged(session: session, window: window)

        case "layout-change":
            // `@0 <layout> <visible layout> <flags>`; older tmux sends only the first
            // layout, so the rest are optional rather than required.
            let fields = rest.split(separator: " ")
            guard fields.count >= 2, let window = Self.windowID(String(fields[0])) else {
                return .unrecognised(name: name, arguments: rest)
            }
            return .layoutChange(
                window: window,
                layout: String(fields[1]),
                visibleLayout: fields.count > 2 ? String(fields[2]) : String(fields[1]),
                flags: fields.count > 3 ? String(fields[3]) : ""
            )

        case "client-detached":
            return .clientDetached(client: rest)

        case "client-session-changed":
            let fields = rest.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count >= 2, let session = Self.sessionID(String(fields[1])) else {
                return .unrecognised(name: name, arguments: rest)
            }
            return .clientSessionChanged(
                client: String(fields[0]),
                session: session,
                name: fields.count > 2 ? String(fields[2]) : ""
            )

        case "pane-mode-changed":
            guard let pane = Self.paneID(rest.trimmingCharacters(in: .whitespaces)) else {
                return .unrecognised(name: name, arguments: rest)
            }
            return .paneModeChanged(pane: pane)

        case "pause", "continue":
            guard let pane = Self.paneID(rest.trimmingCharacters(in: .whitespaces)) else {
                return .unrecognised(name: name, arguments: rest)
            }
            return name == "pause" ? .pause(pane: pane) : .resume(pane: pane)

        case "subscription-changed":
            let fields = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            return .subscriptionChanged(
                name: fields.first.map(String.init) ?? "",
                rest: fields.count > 1 ? String(fields[1]) : ""
            )

        case "message":
            return .message(rest)

        case "exit":
            return .exit(reason: rest.isEmpty ? nil : rest)

        default:
            return .unrecognised(name: name, arguments: rest)
        }
    }

    /// The pane id and where its payload starts in the original bytes.
    private static func paneAndOffset(rest: String, lineBytes: [UInt8], name: String) -> (TmuxPaneID, Int)? {
        guard let space = rest.firstIndex(of: " ") else { return nil }
        guard let pane = paneID(String(rest[..<space])) else { return nil }
        let prefix = "%\(name) \(rest[..<space]) "
        let offset = prefix.utf8.count
        return offset <= lineBytes.count ? (pane, offset) : (pane, lineBytes.count)
    }

    static func paneID(_ text: String) -> TmuxPaneID? {
        guard text.hasPrefix("%"), let number = Int(text.dropFirst()) else { return nil }
        return TmuxPaneID(number)
    }

    static func windowID(_ text: String) -> TmuxWindowID? {
        guard text.hasPrefix("@"), let number = Int(text.dropFirst()) else { return nil }
        return TmuxWindowID(number)
    }

    static func sessionID(_ text: String) -> TmuxSessionID? {
        guard text.hasPrefix("$"), let number = Int(text.dropFirst()) else { return nil }
        return TmuxSessionID(number)
    }

    /// Undoes tmux's escaping: `\ooo`, three octal digits, for every byte it will not send
    /// literally — which includes the backslash itself as `\134`, so a bare backslash is
    /// not part of the protocol. One that appears anyway is passed through rather than
    /// dropped: a client that eats bytes it cannot explain corrupts a terminal silently.
    static func unescape(_ bytes: [UInt8]) -> [UInt8] {
        guard bytes.contains(0x5C) else { return bytes }
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let byte = bytes[index]
            guard byte == 0x5C, index + 3 < bytes.endIndex else {
                result.append(byte)
                index += 1
                continue
            }
            let digits = bytes[(index + 1)...(index + 3)]
            guard digits.allSatisfy({ $0 >= 0x30 && $0 <= 0x37 }) else {
                result.append(byte)
                index += 1
                continue
            }
            let value = digits.reduce(0) { $0 * 8 + Int($1 - 0x30) }
            guard value <= 0xFF else {
                result.append(byte)
                index += 1
                continue
            }
            result.append(UInt8(value))
            index += 4
        }
        return result
    }
}
