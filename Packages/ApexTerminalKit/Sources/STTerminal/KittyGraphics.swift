import Foundation

/// The Kitty graphics protocol (D-065).
///
/// A command arrives as `APC G <k=v,…> ; <base64> ST`. The control data says what to do
/// with the payload; the payload is the picture, sent in pieces small enough that no single
/// escape sequence is enormous. Kitty also defines ways to hand over a *file* — a path, a
/// temporary file, shared memory — and those describe the filesystem of whichever machine
/// runs the program. Over SSH that is the server, and this app is not on it, so those are
/// answered with `ENOTSUPPORTED` rather than pretended.
public struct KittyCommand: Sendable, Equatable {
    public var keys: [String: String]
    public var payload: [UInt8]

    public init(keys: [String: String] = [:], payload: [UInt8] = []) {
        self.keys = keys
        self.payload = payload
    }

    public func integer(_ key: String) -> Int? {
        keys[key].flatMap(Int.init)
    }

    public func string(_ key: String) -> String? { keys[key] }

    /// `a` — what the sender wants done. Transmit, transmit-and-display, display a stored
    /// image, delete, or ask whether this terminal speaks the protocol at all.
    public enum Action: String, Sendable {
        case transmit = "t"
        case transmitAndDisplay = "T"
        case display = "p"
        case delete = "d"
        case query = "q"
        case animationFrame = "f"
        case animationControl = "a"
        case compose = "c"
    }

    public var action: Action {
        keys["a"].flatMap(Action.init(rawValue:)) ?? .transmit
    }

    /// Parses one APC payload, which has already had `APC` and `ST` removed.
    ///
    /// Returns nil when this is not a graphics command — an APC sequence belongs to whoever
    /// claims its first byte, and `G` is Kitty's.
    public static func parse(_ apc: [UInt8]) -> KittyCommand? {
        guard let first = apc.first, first == UInt8(ascii: "G") else { return nil }
        var body = apc.dropFirst()

        var controlBytes: ArraySlice<UInt8>
        if let separator = body.firstIndex(of: UInt8(ascii: ";")) {
            controlBytes = body[body.startIndex ..< separator]
            body = body[(separator + 1)...]
        } else {
            controlBytes = body
            body = body[body.endIndex...]
        }

        var keys: [String: String] = [:]
        for pair in controlBytes.split(separator: UInt8(ascii: ",")) {
            guard let equals = pair.firstIndex(of: UInt8(ascii: "=")) else { continue }
            let key = String(decoding: pair[pair.startIndex ..< equals], as: UTF8.self)
            let value = String(decoding: pair[(equals + 1)...], as: UTF8.self)
            guard !key.isEmpty else { continue }
            keys[key] = value
        }

        // Base64 is decoded here rather than later so a payload that is not base64 is one
        // error in one place, and so the accumulated size is the decoded size.
        let payload: [UInt8]
        if body.isEmpty {
            payload = []
        } else if let data = Data(base64Encoded: Data(body), options: [.ignoreUnknownCharacters]) {
            payload = [UInt8](data)
        } else {
            return KittyCommand(keys: keys, payload: [])
        }
        return KittyCommand(keys: keys, payload: payload)
    }
}
