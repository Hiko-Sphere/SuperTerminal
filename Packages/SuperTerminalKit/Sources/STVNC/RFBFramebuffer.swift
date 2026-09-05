import Compression
import Foundation
import NIOConcurrencyHelpers
import NIOCore
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The remote screen as BGRA pixels, updated rectangle by rectangle. Decoders write into it
/// directly in the client's pixel format (D-022), so a frame is a copy to the display.
public final class RFBFramebuffer: @unchecked Sendable {
    public private(set) var width: Int
    public private(set) var height: Int
    /// BGRA, row-major, 4 bytes per pixel. Written by the decoder on the channel's event
    /// loop and read by the renderer; every crossing goes through `withLock`.
    public private(set) var pixels: [UInt8]
    private let lock = NIOLock()

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
    }

    /// Runs `body` with the pixels held still. The decoder takes it per rectangle, the
    /// renderer per frame; neither ever sees a rectangle half-written.
    public func withLock<T>(_ body: () throws -> T) rethrows -> T {
        try lock.withLock(body)
    }

    /// A copy of the whole screen, taken under the lock.
    public func snapshot() -> (width: Int, height: Int, pixels: Data) {
        lock.withLock { (width, height, Data(pixels)) }
    }

    #if canImport(CoreGraphics)
    /// The screen as an image in the display's own pixel format — BGRX in memory, which
    /// is what `byteOrder32Little` with a skipped first alpha byte names — so the copy
    /// here is the only work between a decoded rectangle and the glass.
    public func makeImage() -> CGImage? {
        let (width, height, data) = snapshot()
        guard width > 0, height > 0, data.count == width * height * 4,
              let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
    #endif

    public func resize(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
    }

    public func pixel(x: Int, y: Int) -> (b: UInt8, g: UInt8, r: UInt8) {
        lock.withLock {
            let i = (y * width + x) * 4
            return (pixels[i], pixels[i + 1], pixels[i + 2])
        }
    }

    @inline(__always) func fill(x: Int, y: Int, w: Int, h: Int, b: UInt8, g: UInt8, r: UInt8) {
        guard w > 0, h > 0 else { return }
        for row in y ..< min(y + h, height) {
            var i = (row * width + x) * 4
            for _ in x ..< min(x + w, width) {
                pixels[i] = b; pixels[i + 1] = g; pixels[i + 2] = r; pixels[i + 3] = 255
                i += 4
            }
        }
    }

    @inline(__always) func put(x: Int, y: Int, b: UInt8, g: UInt8, r: UInt8) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        let i = (y * width + x) * 4
        pixels[i] = b; pixels[i + 1] = g; pixels[i + 2] = r; pixels[i + 3] = 255
    }

    func copyRect(srcX: Int, srcY: Int, x: Int, y: Int, w: Int, h: Int) {
        // Rows may overlap; copy through a temporary so the source is read before it moves.
        var rows: [[UInt8]] = []
        rows.reserveCapacity(h)
        for row in 0 ..< h {
            let start = ((srcY + row) * width + srcX) * 4
            rows.append(Array(pixels[start ..< start + w * 4]))
        }
        for (row, bytes) in rows.enumerated() {
            let start = ((y + row) * width + x) * 4
            pixels.replaceSubrange(start ..< start + w * 4, with: bytes)
        }
    }
}

/// Decodes one rectangle's payload per encoding. Each function returns false when the
/// buffer does not yet hold the whole rectangle, leaving the reader index untouched so
/// the caller can wait for more bytes.
public enum RFBDecoder {
    public enum Failure: Error { case unsupportedEncoding(Int32), malformed(String) }

    public static func decode(rect: RFB.Rectangle, from buffer: inout ByteBuffer, into fb: RFBFramebuffer, zlib: ZlibInflater) throws -> Bool {
        switch RFB.Encoding(rawValue: rect.encoding) {
        case .raw: return raw(rect, &buffer, fb)
        case .copyRect: return copyRect(rect, &buffer, fb)
        case .rre: return rre(rect, &buffer, fb)
        case .hextile: return hextile(rect, &buffer, fb)
        case .zrle: return try zrle(rect, &buffer, fb, zlib)
        case .desktopSize: fb.resize(width: rect.width, height: rect.height); return true
        case .cursor: return cursor(rect, &buffer)
        case .none: throw Failure.unsupportedEncoding(rect.encoding)
        }
    }

    @inline(__always) private static func readPixel(_ buffer: inout ByteBuffer) -> (UInt8, UInt8, UInt8)? {
        guard let b: UInt8 = buffer.readInteger(), let g: UInt8 = buffer.readInteger(),
              let r: UInt8 = buffer.readInteger(), let _: UInt8 = buffer.readInteger() else { return nil }
        return (b, g, r)
    }

    static func raw(_ rect: RFB.Rectangle, _ buffer: inout ByteBuffer, _ fb: RFBFramebuffer) -> Bool {
        let needed = rect.width * rect.height * 4
        guard buffer.readableBytes >= needed else { return false }
        for row in 0 ..< rect.height {
            for column in 0 ..< rect.width {
                guard let (b, g, r) = readPixel(&buffer) else { return false }
                fb.put(x: rect.x + column, y: rect.y + row, b: b, g: g, r: r)
            }
        }
        return true
    }

    static func copyRect(_ rect: RFB.Rectangle, _ buffer: inout ByteBuffer, _ fb: RFBFramebuffer) -> Bool {
        guard buffer.readableBytes >= 4, let srcX: UInt16 = buffer.readInteger(), let srcY: UInt16 = buffer.readInteger() else { return false }
        fb.copyRect(srcX: Int(srcX), srcY: Int(srcY), x: rect.x, y: rect.y, w: rect.width, h: rect.height)
        return true
    }

    static func rre(_ rect: RFB.Rectangle, _ buffer: inout ByteBuffer, _ fb: RFBFramebuffer) -> Bool {
        let start = buffer.readerIndex
        guard let count: UInt32 = buffer.readInteger(), let (bb, bg, br) = readPixel(&buffer) else { buffer.moveReaderIndex(to: start); return false }
        guard buffer.readableBytes >= Int(count) * 12 else { buffer.moveReaderIndex(to: start); return false }
        fb.fill(x: rect.x, y: rect.y, w: rect.width, h: rect.height, b: bb, g: bg, r: br)
        for _ in 0 ..< Int(count) {
            guard let (b, g, r) = readPixel(&buffer), let x: UInt16 = buffer.readInteger(), let y: UInt16 = buffer.readInteger(),
                  let w: UInt16 = buffer.readInteger(), let h: UInt16 = buffer.readInteger() else { return false }
            fb.fill(x: rect.x + Int(x), y: rect.y + Int(y), w: Int(w), h: Int(h), b: b, g: g, r: r)
        }
        return true
    }

    static func hextile(_ rect: RFB.Rectangle, _ buffer: inout ByteBuffer, _ fb: RFBFramebuffer) -> Bool {
        let start = buffer.readerIndex
        var background: (UInt8, UInt8, UInt8) = (0, 0, 0)
        var foreground: (UInt8, UInt8, UInt8) = (0, 0, 0)
        var ty = rect.y
        while ty < rect.y + rect.height {
            let th = min(16, rect.y + rect.height - ty)
            var tx = rect.x
            while tx < rect.x + rect.width {
                let tw = min(16, rect.x + rect.width - tx)
                guard let subencoding: UInt8 = buffer.readInteger() else { buffer.moveReaderIndex(to: start); return false }
                if subencoding & 1 != 0 { // raw tile
                    guard buffer.readableBytes >= tw * th * 4 else { buffer.moveReaderIndex(to: start); return false }
                    for row in 0 ..< th { for column in 0 ..< tw {
                        guard let (b, g, r) = readPixel(&buffer) else { return false }
                        fb.put(x: tx + column, y: ty + row, b: b, g: g, r: r)
                    } }
                } else {
                    if subencoding & 2 != 0 { guard let p = readPixel(&buffer) else { buffer.moveReaderIndex(to: start); return false }; background = p }
                    if subencoding & 4 != 0 { guard let p = readPixel(&buffer) else { buffer.moveReaderIndex(to: start); return false }; foreground = p }
                    fb.fill(x: tx, y: ty, w: tw, h: th, b: background.0, g: background.1, r: background.2)
                    if subencoding & 8 != 0 {
                        guard let count: UInt8 = buffer.readInteger() else { buffer.moveReaderIndex(to: start); return false }
                        let coloured = subencoding & 16 != 0
                        guard buffer.readableBytes >= Int(count) * (coloured ? 6 : 2) else { buffer.moveReaderIndex(to: start); return false }
                        for _ in 0 ..< Int(count) {
                            var colour = foreground
                            if coloured { guard let p = readPixel(&buffer) else { return false }; colour = p }
                            guard let xy: UInt8 = buffer.readInteger(), let wh: UInt8 = buffer.readInteger() else { return false }
                            fb.fill(x: tx + Int(xy >> 4), y: ty + Int(xy & 15), w: Int(wh >> 4) + 1, h: Int(wh & 15) + 1,
                                    b: colour.0, g: colour.1, r: colour.2)
                        }
                    }
                }
                tx += 16
            }
            ty += 16
        }
        return true
    }

    static func zrle(_ rect: RFB.Rectangle, _ buffer: inout ByteBuffer, _ fb: RFBFramebuffer, _ zlib: ZlibInflater) throws -> Bool {
        guard let length: UInt32 = buffer.getInteger(at: buffer.readerIndex), buffer.readableBytes >= 4 + Int(length) else { return false }
        buffer.moveReaderIndex(forwardBy: 4)
        let compressed = buffer.readBytes(length: Int(length)) ?? []
        let data = try zlib.inflate(compressed)
        var tiles = ByteBuffer(bytes: data)
        var ty = rect.y
        while ty < rect.y + rect.height {
            let th = min(64, rect.y + rect.height - ty)
            var tx = rect.x
            while tx < rect.x + rect.width {
                let tw = min(64, rect.x + rect.width - tx)
                guard let subencoding: UInt8 = tiles.readInteger() else { throw Failure.malformed("zrle tile header") }
                // CPIXEL is 3 bytes for 24-bit depth in a 32-bit format: B G R (little-endian, low three).
                func cpixel() throws -> (UInt8, UInt8, UInt8) {
                    guard let b: UInt8 = tiles.readInteger(), let g: UInt8 = tiles.readInteger(), let r: UInt8 = tiles.readInteger() else { throw Failure.malformed("zrle cpixel") }
                    return (b, g, r)
                }
                switch subencoding {
                case 0: // raw
                    for row in 0 ..< th { for column in 0 ..< tw { let p = try cpixel(); fb.put(x: tx + column, y: ty + row, b: p.0, g: p.1, r: p.2) } }
                case 1: // solid
                    let p = try cpixel(); fb.fill(x: tx, y: ty, w: tw, h: th, b: p.0, g: p.1, r: p.2)
                case 2 ... 16: // packed palette
                    let size = Int(subencoding)
                    var palette: [(UInt8, UInt8, UInt8)] = []
                    for _ in 0 ..< size { palette.append(try cpixel()) }
                    let bits = size == 2 ? 1 : size <= 4 ? 2 : 4
                    for row in 0 ..< th {
                        var bitsLeft = 0; var byte: UInt8 = 0
                        for column in 0 ..< tw {
                            if bitsLeft == 0 { guard let b: UInt8 = tiles.readInteger() else { throw Failure.malformed("zrle packed") }; byte = b; bitsLeft = 8 }
                            bitsLeft -= bits
                            let index = Int((byte >> UInt8(bitsLeft)) & UInt8((1 << bits) - 1))
                            let p = palette[min(index, palette.count - 1)]
                            fb.put(x: tx + column, y: ty + row, b: p.0, g: p.1, r: p.2)
                        }
                    }
                case 128: // plain RLE
                    var index = 0
                    while index < tw * th {
                        let p = try cpixel()
                        var run = 1
                        while true { guard let b: UInt8 = tiles.readInteger() else { throw Failure.malformed("zrle rle") }; run += Int(b); if b != 255 { break } }
                        for _ in 0 ..< run where index < tw * th { fb.put(x: tx + index % tw, y: ty + index / tw, b: p.0, g: p.1, r: p.2); index += 1 }
                    }
                case 130 ... 255: // palette RLE
                    let size = Int(subencoding - 128)
                    var palette: [(UInt8, UInt8, UInt8)] = []
                    for _ in 0 ..< size { palette.append(try cpixel()) }
                    var index = 0
                    while index < tw * th {
                        guard let head: UInt8 = tiles.readInteger() else { throw Failure.malformed("zrle prle") }
                        let p = palette[min(Int(head & 127), palette.count - 1)]
                        var run = 1
                        if head & 128 != 0 {
                            while true { guard let b: UInt8 = tiles.readInteger() else { throw Failure.malformed("zrle prle run") }; run += Int(b); if b != 255 { break } }
                        }
                        for _ in 0 ..< run where index < tw * th { fb.put(x: tx + index % tw, y: ty + index / tw, b: p.0, g: p.1, r: p.2); index += 1 }
                    }
                default:
                    throw Failure.malformed("zrle subencoding \(subencoding)")
                }
                tx += 64
            }
            ty += 64
        }
        return true
    }

    /// The Cursor pseudo-encoding carries a cursor image and mask; the client draws the
    /// system pointer instead, so the payload is consumed and dropped.
    static func cursor(_ rect: RFB.Rectangle, _ buffer: inout ByteBuffer) -> Bool {
        let needed = rect.width * rect.height * 4 + ((rect.width + 7) / 8) * rect.height
        guard buffer.readableBytes >= needed else { return false }
        buffer.moveReaderIndex(forwardBy: needed)
        return true
    }
}

/// A zlib stream that persists across rectangles, as ZRLE requires: the server opens one
/// deflate stream per connection and every rectangle continues it.
public final class ZlibInflater {
    private var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>.allocate(capacity: 1), dst_size: 0, src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
    private var ready = false
    private var sawHeader = false

    public init() {}
    deinit { if ready { compression_stream_destroy(&stream) } }

    public func inflate(_ input: [UInt8]) throws -> [UInt8] {
        if !ready {
            guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { throw RFBDecoder.Failure.malformed("zlib init") }
            ready = true
        }
        // Apple's ZLIB is raw deflate; RFB's stream starts with a 2-byte zlib header.
        var bytes = input
        if !sawHeader, bytes.count >= 2 { bytes.removeFirst(2); sawHeader = true }
        var output: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        try bytes.withUnsafeBufferPointer { src in
            stream.src_ptr = src.baseAddress!
            stream.src_size = src.count
            repeat {
                try chunk.withUnsafeMutableBufferPointer { dst in
                    stream.dst_ptr = dst.baseAddress!
                    stream.dst_size = dst.count
                    let status = compression_stream_process(&stream, 0)
                    guard status != COMPRESSION_STATUS_ERROR else { throw RFBDecoder.Failure.malformed("zlib") }
                    output.append(contentsOf: dst.prefix(dst.count - stream.dst_size))
                }
            } while stream.src_size > 0 || stream.dst_size == 0
        }
        return output
    }
}
