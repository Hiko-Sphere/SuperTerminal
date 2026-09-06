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
        let firstRow = max(0, y), lastRow = min(y + h, height)
        let firstColumn = max(0, x), lastColumn = min(x + w, width)
        guard firstRow < lastRow, firstColumn < lastColumn else { return }
        var pattern: UInt32 = 0
        withUnsafeMutableBytes(of: &pattern) { bytes in
            bytes[0] = b; bytes[1] = g; bytes[2] = r; bytes[3] = 255
        }
        let rowBytes = (lastColumn - firstColumn) * 4
        let width = width
        pixels.withUnsafeMutableBytes { destination in
            guard let base = destination.baseAddress else { return }
            for row in firstRow ..< lastRow {
                memset_pattern4(base + (row * width + firstColumn) * 4, &pattern, rowBytes)
            }
        }
    }

    /// Runs `body` with the pixels, their width and their height, for decoders that write
    /// enough of them that going through `put` — a call and four bounds checks each —
    /// dominates. Only ever called with the lock already held.
    func withUnsafeMutablePixels<T>(_ body: (UnsafeMutableRawPointer, Int, Int) throws -> T) rethrows -> T? {
        let width = width, height = height
        return try pixels.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return nil }
            return try body(base, width, height)
        }
    }

    /// Copies a rectangle of wire pixels straight in, clipped to the framebuffer (D-030).
    ///
    /// The pixel format the client negotiates is the framebuffer's own — 32 bits little
    /// endian with blue, green and red in the low three bytes — so a row of a Raw
    /// rectangle is a copy, not a loop. Decoding it pixel by pixel was the slowest thing
    /// in the client by a wide margin. The fourth byte is padding on both sides and is
    /// copied through: the image ignores it.
    func copyPixels(from source: UnsafeRawBufferPointer, rect: RFB.Rectangle) {
        guard let sourceBase = source.baseAddress else { return }
        let firstRow = max(0, rect.y), lastRow = min(rect.y + rect.height, height)
        let firstColumn = max(0, rect.x), lastColumn = min(rect.x + rect.width, width)
        guard firstRow < lastRow, firstColumn < lastColumn else { return }
        let rowBytes = (lastColumn - firstColumn) * 4
        let width = width
        pixels.withUnsafeMutableBytes { destination in
            guard let base = destination.baseAddress else { return }
            for row in firstRow ..< lastRow {
                let sourceOffset = ((row - rect.y) * rect.width + (firstColumn - rect.x)) * 4
                let targetOffset = (row * width + firstColumn) * 4
                (base + targetOffset).copyMemory(from: sourceBase + sourceOffset, byteCount: rowBytes)
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
        guard needed > 0, buffer.readableBytes >= needed else { return needed == 0 }
        buffer.readWithUnsafeReadableBytes { source in
            fb.copyPixels(from: UnsafeRawBufferPointer(rebasing: source.prefix(needed)), rect: rect)
            return needed
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

        // Decoded over raw memory rather than a `ByteBuffer`, and written through a
        // pointer rather than `put` (D-030). Every byte of a ZRLE tile used to cost a
        // `readInteger` call and every pixel a call with four bounds checks; in a build
        // with no inlining — the one you install from Xcode — a full screen took a
        // second. The arithmetic is the same; only the calls are gone.
        let ok = try data.withUnsafeBufferPointer { source -> Bool in
            try fb.withUnsafeMutablePixels { pixelBase, fbWidth, fbHeight -> Bool in
                var cursor = 0
                let end = source.count
                // Plain pointers rather than buffer subscripts and `storeBytes`: both are
                // bounds-checked calls in the configuration this ships to a device in, and
                // this loop runs once per pixel of the screen.
                guard let source = source.baseAddress else { return true }
                let pixels = pixelBase.assumingMemoryBound(to: UInt8.self)

                /// Writes one pixel, dropping any that falls outside the framebuffer.
                @inline(__always) func put(_ x: Int, _ y: Int, _ b: UInt8, _ g: UInt8, _ r: UInt8) {
                    guard x >= 0, y >= 0, x < fbWidth, y < fbHeight else { return }
                    let target = (y * fbWidth + x) * 4
                    pixels[target] = b
                    pixels[target + 1] = g
                    pixels[target + 2] = r
                    pixels[target + 3] = 255
                }

                var ty = rect.y
                while ty < rect.y + rect.height {
                    let th = min(64, rect.y + rect.height - ty)
                    var tx = rect.x
                    while tx < rect.x + rect.width {
                        let tw = min(64, rect.x + rect.width - tx)
                        guard cursor < end else { throw Failure.malformed("zrle tile header") }
                        let subencoding = source[cursor]
                        cursor += 1

                        switch subencoding {
                        case 0:
                            // Raw: one CPIXEL — blue, green, red — per pixel. Clamped once
                            // per row and written straight through, because a per-pixel
                            // call is not inlined in the configuration this ships to a
                            // device in, and this is the tile a detailed screen is made of.
                            let needed = tw * th * 3
                            guard end - cursor >= needed else { throw Failure.malformed("zrle raw tile") }
                            let firstRow = max(0, ty), lastRow = min(ty + th, fbHeight)
                            let firstColumn = max(0, tx), lastColumn = min(tx + tw, fbWidth)
                            if firstRow < lastRow, firstColumn < lastColumn {
                                for row in firstRow ..< lastRow {
                                    var target = (row * fbWidth + firstColumn) * 4
                                    var at = cursor + ((row - ty) * tw + (firstColumn - tx)) * 3
                                    for _ in firstColumn ..< lastColumn {
                                        pixels[target] = source[at]
                                        pixels[target + 1] = source[at + 1]
                                        pixels[target + 2] = source[at + 2]
                                        pixels[target + 3] = 255
                                        target += 4
                                        at += 3
                                    }
                                }
                            }
                            cursor += needed

                        case 1:
                            // Filled here rather than through `fill`, which would be a
                            // second exclusive access to the pixels this closure holds.
                            guard end - cursor >= 3 else { throw Failure.malformed("zrle solid tile") }
                            var pattern: UInt32 = 0
                            withUnsafeMutableBytes(of: &pattern) { bytes in
                                bytes[0] = source[cursor]; bytes[1] = source[cursor + 1]
                                bytes[2] = source[cursor + 2]; bytes[3] = 255
                            }
                            cursor += 3
                            let firstRow = max(0, ty), lastRow = min(ty + th, fbHeight)
                            let firstColumn = max(0, tx), lastColumn = min(tx + tw, fbWidth)
                            if firstRow < lastRow, firstColumn < lastColumn {
                                let rowBytes = (lastColumn - firstColumn) * 4
                                for row in firstRow ..< lastRow {
                                    memset_pattern4(pixels + (row * fbWidth + firstColumn) * 4, &pattern, rowBytes)
                                }
                            }

                        case 2 ... 16:
                            let size = Int(subencoding)
                            let bits = size == 2 ? 1 : size <= 4 ? 2 : 4
                            let rowBytes = (tw * bits + 7) / 8
                            guard end - cursor >= size * 3 + rowBytes * th else { throw Failure.malformed("zrle packed palette") }
                            let paletteAt = cursor
                            cursor += size * 3
                            let mask = UInt8((1 << bits) - 1)
                            for row in 0 ..< th {
                                let rowAt = cursor + row * rowBytes
                                var bitsLeft = 0
                                var byte: UInt8 = 0
                                var byteAt = rowAt
                                for column in 0 ..< tw {
                                    if bitsLeft == 0 {
                                        byte = source[byteAt]
                                        byteAt += 1
                                        bitsLeft = 8
                                    }
                                    bitsLeft -= bits
                                    let index = min(Int((byte >> UInt8(bitsLeft)) & mask), size - 1)
                                    let at = paletteAt + index * 3
                                    put(tx + column, ty + row, source[at], source[at + 1], source[at + 2])
                                }
                            }
                            cursor += rowBytes * th

                        case 128:
                            // Plain run-length: a colour, then a run written as 255s.
                            var index = 0
                            let count = tw * th
                            while index < count {
                                guard end - cursor >= 3 else { throw Failure.malformed("zrle rle") }
                                let b = source[cursor], g = source[cursor + 1], r = source[cursor + 2]
                                cursor += 3
                                var run = 1
                                while true {
                                    guard cursor < end else { throw Failure.malformed("zrle rle run") }
                                    let length = source[cursor]
                                    cursor += 1
                                    run += Int(length)
                                    if length != 255 { break }
                                }
                                let last = min(index + run, count)
                                while index < last {
                                    put(tx + index % tw, ty + index / tw, b, g, r)
                                    index += 1
                                }
                            }

                        case 130 ... 255:
                            let size = Int(subencoding) - 128
                            guard end - cursor >= size * 3 else { throw Failure.malformed("zrle palette rle") }
                            let paletteAt = cursor
                            cursor += size * 3
                            var index = 0
                            let count = tw * th
                            while index < count {
                                guard cursor < end else { throw Failure.malformed("zrle prle") }
                                let head = source[cursor]
                                cursor += 1
                                let at = paletteAt + min(Int(head & 127), size - 1) * 3
                                let b = source[at], g = source[at + 1], r = source[at + 2]
                                var run = 1
                                if head & 128 != 0 {
                                    while true {
                                        guard cursor < end else { throw Failure.malformed("zrle prle run") }
                                        let length = source[cursor]
                                        cursor += 1
                                        run += Int(length)
                                        if length != 255 { break }
                                    }
                                }
                                let last = min(index + run, count)
                                while index < last {
                                    put(tx + index % tw, ty + index / tw, b, g, r)
                                    index += 1
                                }
                            }

                        default:
                            throw Failure.malformed("zrle subencoding \(subencoding)")
                        }
                        tx += 64
                    }
                    ty += 64
                }
                return true
            } ?? false
        }
        return ok
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
