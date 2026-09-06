import Compression
import Foundation
import NIOCore
import Testing
@testable import STVNC

/// How fast a screen can actually be drawn (D-030).
///
/// A remote desktop is only usable if a frame decodes in a fraction of the time between
/// frames. These measure the decoders on a 1080p framebuffer — the size a real desktop
/// sends — and hold them to floors slow enough not to be flaky on a loaded machine and
/// fast enough that failing one means the screen would visibly lag.
@Suite("VNC throughput", .serialized)
struct VNCThroughputTests {
    private static let width = 1920
    private static let height = 1080

    /// Debug builds carry bounds checks and no inlining across modules; the floors are
    /// the ones that matter for a release build — the configuration this ships in — divided
    /// for the configuration the suite usually runs in. `debugDivisor` is per test because
    /// the gap is not uniform: a decoder that is one `memcpy` a row loses almost nothing to
    /// Debug, while one that touches every pixel individually loses a factor of forty.
    private func floor(release: Double, debugDivisor: Double = 8) -> Double {
        #if DEBUG
        release / debugDivisor
        #else
        release
        #endif
    }

    private func measure(_ body: () -> Void) -> Double {
        let start = ContinuousClock.now
        body()
        return Double((ContinuousClock.now - start).components.attoseconds) / 1e18
            + Double((ContinuousClock.now - start).components.seconds)
    }

    /// A full-screen Raw rectangle: what every server sends for the first frame, and what
    /// a server with no better encoding sends for every frame after it.
    @Test("A full 1080p Raw frame decodes fast enough to keep up with a desktop")
    func rawFullFrame() throws {
        let fb = RFBFramebuffer(width: Self.width, height: Self.height)
        var wire = [UInt8](repeating: 0, count: Self.width * Self.height * 4)
        for i in stride(from: 0, to: wire.count, by: 4) {
            wire[i] = UInt8(truncatingIfNeeded: i / 4)
            wire[i + 1] = UInt8(truncatingIfNeeded: (i / 4) >> 8)
            wire[i + 2] = UInt8(truncatingIfNeeded: (i / 4) >> 16)
        }
        let rect = RFB.Rectangle(x: 0, y: 0, width: Self.width, height: Self.height, encoding: RFB.Encoding.raw.rawValue)

        let frames = 20
        let seconds = measure {
            for _ in 0 ..< frames {
                var buffer = ByteBuffer(bytes: wire)
                _ = try? fb.withLock { try RFBDecoder.decode(rect: rect, from: &buffer, into: fb, zlib: ZlibInflater()) }
            }
        }
        let fps = Double(frames) / seconds
        // The pixels are the same bytes on the wire as in the framebuffer, so a row is a
        // copy: hundreds of frames a second, not tens.
        #expect(fps > floor(release: 1500), "Raw decode managed \(Int(fps)) fps at 1920×1080")

        // The picture is right, not merely fast.
        let p = fb.pixel(x: 1, y: 0)
        #expect(p.b == 1 && p.g == 0 && p.r == 0)
        let q = fb.pixel(x: 0, y: 1)
        let index = Self.width
        #expect(q.b == UInt8(truncatingIfNeeded: index) && q.g == UInt8(truncatingIfNeeded: index >> 8))
    }

    /// Solid tiles are what a desktop mostly sends: flat colour behind windows.
    @Test("A full 1080p Hextile frame of solid tiles decodes fast enough")
    func hextileSolidTiles() throws {
        let fb = RFBFramebuffer(width: Self.width, height: Self.height)
        var wire = ByteBuffer()
        let tilesAcross = (Self.width + 15) / 16
        let tilesDown = (Self.height + 15) / 16
        for _ in 0 ..< tilesAcross * tilesDown {
            wire.writeInteger(UInt8(2))            // background only
            wire.writeBytes([9, 8, 7, 0])          // one CPIXEL
        }
        let bytes = Array(wire.readableBytesView)
        let rect = RFB.Rectangle(x: 0, y: 0, width: Self.width, height: Self.height, encoding: RFB.Encoding.hextile.rawValue)

        let frames = 20
        let seconds = measure {
            for _ in 0 ..< frames {
                var buffer = ByteBuffer(bytes: bytes)
                _ = try? fb.withLock { try RFBDecoder.decode(rect: rect, from: &buffer, into: fb, zlib: ZlibInflater()) }
            }
        }
        let fps = Double(frames) / seconds
        #expect(fps > floor(release: 120), "Hextile decode managed \(Int(fps)) fps at 1920×1080")
        #expect(fb.pixel(x: 100, y: 100) == (9, 8, 7))
    }

    /// ZRLE is the encoding the client asks for first, so it is the one a real server
    /// uses — and its tiles are decoded pixel by pixel out of an inflated buffer.
    @Test("A full 1080p ZRLE frame decodes fast enough")
    func zrleFullFrame() throws {
        let fb = RFBFramebuffer(width: Self.width, height: Self.height)
        // 64×64 tiles, alternating solid and raw: a desktop is mostly flat colour with
        // some detail, and raw tiles are the expensive half.
        var tiles = [UInt8]()
        let across = (Self.width + 63) / 64, down = (Self.height + 63) / 64
        for index in 0 ..< across * down {
            if index % 2 == 0 {
                tiles.append(1)                                  // solid
                tiles.append(contentsOf: [7, 8, 9])              // CPIXEL
            } else {
                tiles.append(0)                                  // raw
                for pixel in 0 ..< 64 * 64 {
                    tiles.append(contentsOf: [UInt8(truncatingIfNeeded: pixel), 2, 3])
                }
            }
        }
        var payload = ByteBuffer()
        let compressed = try Self.deflate(tiles)
        payload.writeInteger(UInt32(compressed.count))
        payload.writeBytes(compressed)
        let bytes = Array(payload.readableBytesView)
        let rect = RFB.Rectangle(x: 0, y: 0, width: Self.width, height: Self.height, encoding: RFB.Encoding.zrle.rawValue)

        let frames = 10
        let seconds = measure {
            for _ in 0 ..< frames {
                var buffer = ByteBuffer(bytes: bytes)
                let zlib = ZlibInflater()
                _ = try? fb.withLock { try RFBDecoder.decode(rect: rect, from: &buffer, into: fb, zlib: zlib) }
            }
        }
        let fps = Double(frames) / seconds
        // Measured at 568 fps release, 13 in Debug, on this frame — the worst kind a
        // server sends, half of it raw tiles. The floor is well under both and still far
        // enough above a lagging screen that failing it means the picture stutters.
        #expect(fps > floor(release: 240, debugDivisor: 40), "ZRLE decode managed \(Int(fps)) fps at 1920×1080")
        #expect(fb.pixel(x: 10, y: 10) == (7, 8, 9), "the solid tile is there")
    }

    /// A zlib stream as a server begins one: a two-byte header, then deflate data.
    private static func deflate(_ bytes: [UInt8]) throws -> [UInt8] {
        var destination = [UInt8](repeating: 0, count: bytes.count + 4096)
        let count = bytes.withUnsafeBufferPointer { source in
            destination.withUnsafeMutableBufferPointer { dest in
                compression_encode_buffer(dest.baseAddress!, dest.count, source.baseAddress!, source.count, nil, COMPRESSION_ZLIB)
            }
        }
        return [0x78, 0x9C] + Array(destination.prefix(count))
    }

    /// The image handed to the display, once per frame.
    @Test("Turning the framebuffer into an image keeps up with the display")
    func imageCreation() {
        let fb = RFBFramebuffer(width: Self.width, height: Self.height)
        let frames = 60
        let seconds = measure {
            for _ in 0 ..< frames { _ = fb.makeImage() }
        }
        let fps = Double(frames) / seconds
        #expect(fps > floor(release: 120), "image creation managed \(Int(fps)) fps at 1920×1080")
    }
}
