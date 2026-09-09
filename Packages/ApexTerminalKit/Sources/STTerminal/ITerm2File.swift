import Foundation

/// iTerm2's inline images (D-065): `OSC 1337 ; File=<arguments> : <base64> ST`.
///
/// The arguments are `key=value` pairs separated by `;`. Only `inline=1` draws — without it
/// the sequence is asking the terminal to *save a file the server chose*, which this app
/// does not do: a program on a machine you connected to should not be able to write to your
/// device because you ran `cat`.
public struct ITerm2File: Sendable, Equatable {
    public var arguments: [String: String]
    public var data: [UInt8]

    /// A size in one of the four spellings iTerm2 allows.
    public enum Size: Sendable, Equatable {
        case cells(Int)
        case pixels(Int)
        case percent(Int)
        case auto
    }

    public var isInline: Bool { arguments["inline"] == "1" }
    public var movesCursor: Bool { arguments["doNotMoveCursor"] != "1" }
    public var preservesAspectRatio: Bool { arguments["preserveAspectRatio"] != "0" }
    public var width: Size { Self.size(arguments["width"]) }
    public var height: Size { Self.size(arguments["height"]) }

    /// The declared byte count, which is a claim rather than a fact — the data is what it
    /// is, and this is only used to refuse something enormous before decoding it.
    public var declaredSize: Int? { arguments["size"].flatMap(Int.init) }

    static func size(_ value: String?) -> Size {
        guard var text = value?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return .auto }
        if text == "auto" { return .auto }
        if text.hasSuffix("px") {
            text.removeLast(2)
            return Int(text).map(Size.pixels) ?? .auto
        }
        if text.hasSuffix("%") {
            text.removeLast()
            return Int(text).map(Size.percent) ?? .auto
        }
        return Int(text).map(Size.cells) ?? .auto
    }

    /// Parses an OSC 1337 payload with the `1337;` already removed.
    public static func parse(_ payload: String) -> ITerm2File? {
        guard payload.hasPrefix("File=") || payload.hasPrefix("File:") else { return nil }
        let body = payload.dropFirst("File".count + 1)

        // The arguments end at the first colon; everything after it is base64.
        let argumentText: Substring
        let encoded: Substring
        if let colon = body.firstIndex(of: ":") {
            argumentText = body[body.startIndex ..< colon]
            encoded = body[body.index(after: colon)...]
        } else {
            argumentText = body
            encoded = ""
        }

        var arguments: [String: String] = [:]
        for pair in argumentText.split(separator: ";") {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            let key = String(pair[pair.startIndex ..< equals])
            let value = String(pair[pair.index(after: equals)...])
            guard !key.isEmpty else { continue }
            arguments[key] = value
        }

        let data = Data(base64Encoded: String(encoded), options: [.ignoreUnknownCharacters])
        return ITerm2File(arguments: arguments, data: data.map { [UInt8]($0) } ?? [])
    }
}
