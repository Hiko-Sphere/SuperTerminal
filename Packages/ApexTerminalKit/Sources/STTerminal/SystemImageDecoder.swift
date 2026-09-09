import Compression
import CoreGraphics
import Foundation
import ImageIO

/// Pictures in the formats the system already decodes: PNG, JPEG and GIF (D-065).
///
/// Kitty's `f=100` and iTerm2's inline images both send an encoded file rather than pixels.
/// Decoding those by hand would mean writing parsers for hostile input that the platform
/// already has hardened ones for, so ImageIO does it and the result is copied out as
/// premultiplied RGBA — the one arrangement Core Graphics will draw.
public enum SystemImageDecoder {
    public static func decode(_ payload: [UInt8]) throws -> TerminalImage {
        let data = Data(payload) as CFData
        guard let source = CGImageSourceCreateWithData(data, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw ImageDecodingError.malformed("not a picture this device can read")
        }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { throw ImageDecodingError.empty }
        guard width * height <= TerminalImage.maximumPixels else {
            throw ImageDecodingError.tooLarge(pixels: width * height)
        }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw ImageDecodingError.malformed("could not be drawn") }
        return TerminalImage(width: width, height: height, pixels: pixels)
    }

    /// zlib, as `o=z` means it: RFC 1950's two-byte header and four-byte checksum around
    /// raw DEFLATE, which is what the system's decoder takes.
    public static func inflate(_ payload: [UInt8]) throws -> [UInt8] {
        guard payload.count > 6 else { throw ImageDecodingError.malformed("compressed data is too short") }
        let body = Array(payload[2 ..< (payload.count - 4)])
        var capacity = max(payload.count * 4, 4096)
        while capacity <= TerminalImage.maximumPixels * 4 {
            var output = [UInt8](repeating: 0, count: capacity)
            let written = output.withUnsafeMutableBufferPointer { destination -> Int in
                body.withUnsafeBufferPointer { source in
                    compression_decode_buffer(
                        destination.baseAddress!, destination.count,
                        source.baseAddress!, source.count,
                        nil, COMPRESSION_ZLIB
                    )
                }
            }
            if written == 0 { throw ImageDecodingError.malformed("compressed data could not be read") }
            if written < capacity {
                output.removeLast(capacity - written)
                return output
            }
            // Filled the buffer exactly: it may have been truncated, so try again with room.
            capacity *= 4
        }
        throw ImageDecodingError.tooLarge(pixels: capacity / 4)
    }

}
