import Foundation

/// A tmux window layout: the arrangement its panes are in, and where each one is.
///
/// tmux sends this as one string — `c195,80x24,0,0[80x12,0,0,0,80x11,0,13,1]` — with a
/// checksum in front. Parsing it is what lets a client draw the same arrangement the server
/// has rather than guessing from pane ids, and the checksum is verified rather than skipped:
/// a layout that arrived corrupt would otherwise be drawn as a plausible but wrong screen.
public indirect enum TmuxLayout: Equatable, Sendable {
    case pane(TmuxLayoutFrame, TmuxPaneID)
    /// Panes side by side — tmux writes this with `{}`.
    case leftRight(TmuxLayoutFrame, [TmuxLayout])
    /// Panes stacked — tmux writes this with `[]`.
    case topBottom(TmuxLayoutFrame, [TmuxLayout])

    public var frame: TmuxLayoutFrame {
        switch self {
        case let .pane(frame, _): frame
        case let .leftRight(frame, _): frame
        case let .topBottom(frame, _): frame
        }
    }

    /// Every pane in the layout, in the order tmux wrote them, with where each one sits.
    public var panes: [(id: TmuxPaneID, frame: TmuxLayoutFrame)] {
        switch self {
        case let .pane(frame, id): [(id, frame)]
        case let .leftRight(_, children), let .topBottom(_, children): children.flatMap(\.panes)
        }
    }
}

/// Cells, not points: tmux describes a layout in terminal cells, and converting to points is
/// the drawing code's business.
public struct TmuxLayoutFrame: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let x: Int
    public let y: Int

    public init(width: Int, height: Int, x: Int, y: Int) {
        self.width = width
        self.height = height
        self.x = x
        self.y = y
    }
}

public enum TmuxLayoutError: Error, Equatable {
    case missingChecksum
    /// The checksum tmux sent and the one its own algorithm produces for the rest of the
    /// string. Both are reported: knowing which is which is the difference between "the
    /// line was truncated" and "this client computes the checksum wrongly".
    case checksumMismatch(sent: String, computed: String)
    case malformed(String)
}

public extension TmuxLayout {
    /// Parses `checksum,layout`, verifying the checksum.
    static func parse(_ text: String) throws -> TmuxLayout {
        guard let comma = text.firstIndex(of: ",") else { throw TmuxLayoutError.missingChecksum }
        let checksum = String(text[..<comma])
        let body = String(text[text.index(after: comma)...])
        let computed = String(format: "%04x", Self.checksum(of: body))
        guard checksum.lowercased() == computed else {
            throw TmuxLayoutError.checksumMismatch(sent: checksum, computed: computed)
        }
        var scanner = Scanner(body)
        let layout = try scanner.layout()
        guard scanner.isAtEnd else { throw TmuxLayoutError.malformed(body) }
        return layout
    }

    /// tmux's own `layout_checksum`, a 16-bit rotate-and-add. Reimplemented rather than
    /// approximated: this is the only way to tell a layout that arrived intact from one
    /// that did not, and any other function would reject every layout tmux sends.
    static func checksum(of layout: String) -> UInt16 {
        var csum: UInt16 = 0
        for byte in layout.utf8 {
            csum = (csum >> 1) &+ ((csum & 1) << 15)
            csum = csum &+ UInt16(byte)
        }
        return csum
    }

    /// A recursive-descent scanner over the layout grammar, which is small enough to write
    /// out: `WxH,X,Y` followed by a pane id, `{` for panes side by side, or `[` for stacked.
    private struct Scanner {
        private let characters: [Character]
        private var index: Int = 0

        init(_ text: String) { characters = Array(text) }

        var isAtEnd: Bool { index >= characters.count }

        mutating func layout() throws -> TmuxLayout {
            let width = try number()
            try expect("x")
            let height = try number()
            try expect(",")
            let x = try number()
            try expect(",")
            let y = try number()
            let frame = TmuxLayoutFrame(width: width, height: height, x: x, y: y)

            if peek() == "," {
                index += 1
                return .pane(frame, TmuxPaneID(try number()))
            }
            if peek() == "{" {
                return .leftRight(frame, try children(closing: "}"))
            }
            if peek() == "[" {
                return .topBottom(frame, try children(closing: "]"))
            }
            throw TmuxLayoutError.malformed(String(characters[index...]))
        }

        private mutating func children(closing: Character) throws -> [TmuxLayout] {
            index += 1
            var result: [TmuxLayout] = []
            while true {
                result.append(try layout())
                if peek() == "," { index += 1; continue }
                if peek() == closing { index += 1; break }
                throw TmuxLayoutError.malformed(String(characters[min(index, characters.count)...]))
            }
            return result
        }

        private func peek() -> Character? { index < characters.count ? characters[index] : nil }

        private mutating func expect(_ character: Character) throws {
            guard peek() == character else {
                throw TmuxLayoutError.malformed("expected \(character) at \(index)")
            }
            index += 1
        }

        private mutating func number() throws -> Int {
            let start = index
            while let character = peek(), character.isNumber { index += 1 }
            guard index > start, let value = Int(String(characters[start ..< index])) else {
                throw TmuxLayoutError.malformed("expected a number at \(start)")
            }
            return value
        }
    }
}
