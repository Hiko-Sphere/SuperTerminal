import Foundation

/// Turns a completed Kitty transfer into pixels (D-065).
///
/// Three formats: 24-bit RGB, 32-bit RGBA, and PNG. The first two are just bytes and are
/// unpacked here; PNG is decoded by ImageIO, because writing a PNG decoder would be writing
/// a parser for hostile input that the system already has one for.
public enum KittyImageDecoder {
    /// Kitty's `f=` values.
    static let rgb = 24
    static let rgba = 32
    static let png = 100

    public static func decode(_ command: KittyCommand) throws -> TerminalImage {
        var payload = command.payload
        guard !payload.isEmpty else { throw ImageDecodingError.empty }

        if command.string("o") == "z" {
            payload = try SystemImageDecoder.inflate(payload)
        }

        switch command.integer("f") ?? rgba {
        case rgb, rgba:
            let channels = (command.integer("f") ?? rgba) == rgb ? 3 : 4
            guard let width = command.integer("s"), let height = command.integer("v"),
                  width > 0, height > 0
            else {
                throw ImageDecodingError.malformed("a raw image must say how wide and tall it is")
            }
            guard width * height <= TerminalImage.maximumPixels else {
                throw ImageDecodingError.tooLarge(pixels: width * height)
            }
            guard payload.count >= width * height * channels else {
                throw ImageDecodingError.malformed("the data is shorter than \(width)×\(height) pixels")
            }
            return unpack(payload, width: width, height: height, channels: channels)
        case png:
            return try SystemImageDecoder.decode(payload)
        default:
            throw ImageDecodingError.malformed("unknown format")
        }
    }

    /// Unpacks `f=24` or `f=32`, premultiplying as it goes.
    ///
    /// Kitty's RGBA is straight alpha; Core Graphics draws premultiplied and has no format
    /// for the other kind, so the multiplication happens once here rather than on every
    /// frame. For `f=24` and for anything fully opaque the two are the same bytes.
    static func unpack(_ payload: [UInt8], width: Int, height: Int, channels: Int) -> TerminalImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var source = 0
        var destination = 0
        for _ in 0 ..< (width * height) {
            let alpha = channels == 4 ? Int(payload[source + 3]) : 255
            if alpha == 255 {
                pixels[destination] = payload[source]
                pixels[destination + 1] = payload[source + 1]
                pixels[destination + 2] = payload[source + 2]
            } else if alpha > 0 {
                pixels[destination] = UInt8((Int(payload[source]) * alpha + 127) / 255)
                pixels[destination + 1] = UInt8((Int(payload[source + 1]) * alpha + 127) / 255)
                pixels[destination + 2] = UInt8((Int(payload[source + 2]) * alpha + 127) / 255)
            }
            pixels[destination + 3] = UInt8(alpha)
            source += channels
            destination += 4
        }
        return TerminalImage(width: width, height: height, pixels: pixels)
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case ImageDecodingError.empty: return "no image data"
        case let ImageDecodingError.tooLarge(pixels): return "too large (\(pixels) pixels)"
        case let ImageDecodingError.malformed(reason): return reason
        default: return "could not be read"
        }
    }
}
