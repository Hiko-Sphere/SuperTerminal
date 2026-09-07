import Compression
import Foundation
import NIOCore
import Testing
@testable import STVNC

/// The decoders on hand-built rectangles, byte for byte as RFC 6143 lays them out. The
/// live tests prove them against a real server; these pin the corner cases a server
/// happens not to send — a tile straddling the edge, a run crossing a row, a rectangle
/// arriving in two halves.
@Suite("RFB decoders")
struct RFBDecoderTests {
    private func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ encoding: RFB.Encoding) -> RFB.Rectangle {
        RFB.Rectangle(x: x, y: y, width: w, height: h, encoding: encoding.rawValue)
    }

    private func pixel(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> [UInt8] { [b, g, r, 0] }

    @Test("Raw pixels land where the rectangle says, and a short buffer waits")
    func raw() throws {
        let fb = RFBFramebuffer(width: 4, height: 3)
        var buffer = ByteBuffer(bytes: pixel(1, 2, 3) + pixel(4, 5, 6) + pixel(7, 8, 9) + pixel(10, 11, 12))
        #expect(try RFBDecoder.decode(rect: rect(1, 1, 2, 2, .raw), from: &buffer, into: fb, zlib: ZlibInflater()))
        #expect(fb.pixel(x: 1, y: 1) == (3, 2, 1))
        #expect(fb.pixel(x: 2, y: 1) == (6, 5, 4))
        #expect(fb.pixel(x: 1, y: 2) == (9, 8, 7))
        #expect(fb.pixel(x: 2, y: 2) == (12, 11, 10))
        #expect(fb.pixel(x: 0, y: 0) == (0, 0, 0))

        var short = ByteBuffer(bytes: pixel(1, 2, 3))
        #expect(try RFBDecoder.decode(rect: rect(0, 0, 2, 1, .raw), from: &short, into: fb, zlib: ZlibInflater()) == false)
        #expect(short.readerIndex == 0, "a rectangle that is not all there is left for the next read")
    }

    @Test("CopyRect moves pixels, including onto themselves")
    func copyRect() throws {
        let fb = RFBFramebuffer(width: 4, height: 1)
        var raw = ByteBuffer(bytes: pixel(1, 1, 1) + pixel(2, 2, 2) + pixel(3, 3, 3) + pixel(4, 4, 4))
        _ = try RFBDecoder.decode(rect: rect(0, 0, 4, 1, .raw), from: &raw, into: fb, zlib: ZlibInflater())
        var copy = ByteBuffer()
        copy.writeInteger(UInt16(0)); copy.writeInteger(UInt16(0)) // source x, y
        #expect(try RFBDecoder.decode(rect: rect(1, 0, 3, 1, .copyRect), from: &copy, into: fb, zlib: ZlibInflater()))
        #expect(fb.pixel(x: 1, y: 0).r == 1 && fb.pixel(x: 2, y: 0).r == 2 && fb.pixel(x: 3, y: 0).r == 3,
                "an overlapping copy reads the source before it moves")
    }

    @Test("RRE paints the background, then each subrectangle")
    func rre() throws {
        let fb = RFBFramebuffer(width: 4, height: 4)
        var buffer = ByteBuffer()
        buffer.writeInteger(UInt32(1))
        buffer.writeBytes(pixel(9, 9, 9))
        buffer.writeBytes(pixel(1, 2, 3))
        buffer.writeInteger(UInt16(1)); buffer.writeInteger(UInt16(1)); buffer.writeInteger(UInt16(2)); buffer.writeInteger(UInt16(2))
        #expect(try RFBDecoder.decode(rect: rect(0, 0, 4, 4, .rre), from: &buffer, into: fb, zlib: ZlibInflater()))
        #expect(fb.pixel(x: 0, y: 0).r == 9)
        #expect(fb.pixel(x: 1, y: 1) == (3, 2, 1) && fb.pixel(x: 2, y: 2) == (3, 2, 1))
        #expect(fb.pixel(x: 3, y: 3).r == 9)
    }

    @Test("Hextile: background, foreground, coloured subrectangles, a raw tile, and a tile at the edge")
    func hextile() throws {
        let fb = RFBFramebuffer(width: 20, height: 4)
        var buffer = ByteBuffer()
        // Tile 1 (16 wide): background + foreground + one subrect from the foreground.
        buffer.writeInteger(UInt8(2 | 4 | 8))
        buffer.writeBytes(pixel(10, 10, 10))
        buffer.writeBytes(pixel(20, 20, 20))
        buffer.writeInteger(UInt8(1))
        buffer.writeInteger(UInt8(0x21)) // x=2, y=1
        buffer.writeInteger(UInt8(0x10)) // w-1=1, h-1=0 → 2×1
        // Tile 2 (4 wide, at the edge): raw.
        buffer.writeInteger(UInt8(1))
        for i in 0 ..< 16 { buffer.writeBytes(pixel(UInt8(i), 0, 0)) }
        #expect(try RFBDecoder.decode(rect: rect(0, 0, 20, 4, .hextile), from: &buffer, into: fb, zlib: ZlibInflater()))
        #expect(fb.pixel(x: 0, y: 0).r == 10)
        #expect(fb.pixel(x: 2, y: 1).r == 20 && fb.pixel(x: 3, y: 1).r == 20 && fb.pixel(x: 4, y: 1).r == 10)
        #expect(fb.pixel(x: 16, y: 0).r == 0 && fb.pixel(x: 19, y: 0).r == 3 && fb.pixel(x: 16, y: 1).r == 4)

        // The same tile again, half delivered: nothing is consumed.
        var half = ByteBuffer(bytes: [2 | 4 | 8] + pixel(1, 1, 1))
        #expect(try RFBDecoder.decode(rect: rect(0, 0, 16, 4, .hextile), from: &half, into: fb, zlib: ZlibInflater()) == false)
        #expect(half.readerIndex == 0)
    }

    /// Deflates `bytes` the way a server's zlib stream would begin: a two-byte header,
    /// then deflate data. Apple's encoder writes raw deflate, so the header is added.
    private func zlibStream(_ bytes: [UInt8]) -> [UInt8] {
        var destination = [UInt8](repeating: 0, count: bytes.count + 64)
        let count = bytes.withUnsafeBufferPointer { source in
            destination.withUnsafeMutableBufferPointer { dest in
                compression_encode_buffer(dest.baseAddress!, dest.count, source.baseAddress!, source.count, nil, COMPRESSION_ZLIB)
            }
        }
        return [0x78, 0x9C] + Array(destination.prefix(count))
    }

    @Test("ZRLE: solid, raw, packed-palette and run-length tiles through a zlib stream")
    func zrle() throws {
        let fb = RFBFramebuffer(width: 4, height: 2)
        // A 4×2 rectangle is one tile. Solid tile first.
        var tile: [UInt8] = [1, 3, 2, 1] // solid, CPIXEL b g r
        var payload = zlibStream(tile)
        var buffer = ByteBuffer()
        buffer.writeInteger(UInt32(payload.count)); buffer.writeBytes(payload)
        let zlib = ZlibInflater()
        #expect(try RFBDecoder.decode(rect: rect(0, 0, 4, 2, .zrle), from: &buffer, into: fb, zlib: zlib))
        #expect(fb.pixel(x: 3, y: 1) == (3, 2, 1))

        // Packed palette of two colours, one bit per pixel: row 0 = 1010, row 1 = 0101.
        tile = [2, 0, 0, 0, 9, 9, 9, 0b1010_0000, 0b0101_0000]
        payload = zlibStream(tile)
        buffer = ByteBuffer(); buffer.writeInteger(UInt32(payload.count)); buffer.writeBytes(payload)
        #expect(try RFBDecoder.decode(rect: rect(0, 0, 4, 2, .zrle), from: &buffer, into: fb, zlib: ZlibInflater()))
        #expect(fb.pixel(x: 0, y: 0).r == 9 && fb.pixel(x: 1, y: 0).r == 0 && fb.pixel(x: 0, y: 1).r == 0 && fb.pixel(x: 1, y: 1).r == 9)

        // Plain RLE: a run of 5 (length byte 4) then a run of 3 (length byte 2).
        tile = [128, 5, 5, 5, 4, 6, 6, 6, 2]
        payload = zlibStream(tile)
        buffer = ByteBuffer(); buffer.writeInteger(UInt32(payload.count)); buffer.writeBytes(payload)
        #expect(try RFBDecoder.decode(rect: rect(0, 0, 4, 2, .zrle), from: &buffer, into: fb, zlib: ZlibInflater()))
        #expect(fb.pixel(x: 0, y: 1).r == 5 && fb.pixel(x: 1, y: 1).r == 6, "a run crosses from row 0 into row 1")

        // Palette RLE: palette of two, index 1 with a run of 8 (length byte 7).
        tile = [130, 1, 1, 1, 7, 7, 7, 0x81, 7]
        payload = zlibStream(tile)
        buffer = ByteBuffer(); buffer.writeInteger(UInt32(payload.count)); buffer.writeBytes(payload)
        #expect(try RFBDecoder.decode(rect: rect(0, 0, 4, 2, .zrle), from: &buffer, into: fb, zlib: ZlibInflater()))
        #expect(fb.pixel(x: 3, y: 1).r == 7)
    }

    @Test("DesktopSize resizes the framebuffer; an unknown encoding is an error, not a guess")
    func pseudoEncodingsAndUnknowns() throws {
        let fb = RFBFramebuffer(width: 2, height: 2)
        var empty = ByteBuffer()
        #expect(try RFBDecoder.decode(rect: rect(0, 0, 8, 6, .desktopSize), from: &empty, into: fb, zlib: ZlibInflater()))
        #expect(fb.width == 8 && fb.height == 6)
        #expect(throws: RFBDecoder.Failure.self) {
            _ = try RFBDecoder.decode(rect: RFB.Rectangle(x: 0, y: 0, width: 1, height: 1, encoding: 999), from: &empty, into: fb, zlib: ZlibInflater())
        }
    }

    @Test("The handshake messages are laid out as the protocol says")
    func messageLayout() {
        var buffer = ByteBuffer()
        RFB.pointerEvent(buttons: 0b101, x: 0x1234, y: 0x0102, into: &buffer)
        #expect(Array(buffer.readableBytesView) == [5, 0b101, 0x12, 0x34, 0x01, 0x02])
        buffer.clear()
        RFB.keyEvent(keysym: 0xFF0D, down: true, into: &buffer)
        #expect(Array(buffer.readableBytesView) == [4, 1, 0, 0, 0, 0, 0xFF, 0x0D])
        buffer.clear()
        RFB.clientCutText("héllo€", into: &buffer)
        #expect(Array(buffer.readableBytesView) == [6, 0, 0, 0, 0, 0, 0, 6] + Array("h".utf8) + [0xE9] + Array("llo?".utf8),
                "cut text is Latin-1; what cannot be carried is replaced, not dropped")
        buffer.clear()
        RFB.framebufferUpdateRequest(incremental: true, x: 1, y: 2, width: 3, height: 4, into: &buffer)
        #expect(Array(buffer.readableBytesView) == [3, 1, 0, 1, 0, 2, 0, 3, 0, 4])

        var version = ByteBuffer(string: "RFB 003.008\n")
        let parsed = RFB.readVersion(from: &version)
        #expect(parsed?.major == 3 && parsed?.minor == 8)
        var serverInit = ByteBuffer()
        serverInit.writeInteger(UInt16(640)); serverInit.writeInteger(UInt16(480))
        RFB.PixelFormat.client.write(into: &serverInit)
        serverInit.writeInteger(UInt32(4)); serverInit.writeString("desk")
        let info = RFB.readServerInit(from: &serverInit)
        #expect(info?.width == 640 && info?.height == 480 && info?.name == "desk" && info?.pixelFormat == .client)
    }

    @Test("The VNC authentication challenge is encrypted the way every server expects")
    func desChallenge() {
        // Bits of each password byte are reversed before keying — the historic VNC quirk;
        // a client that skips it is refused by every server there is.
        #expect(VNCDES.reverseBits(0b0000_0001) == 0b1000_0000)
        #expect(VNCDES.reverseBits(0b1011_0000) == 0b0000_1101)
        let challenge: [UInt8] = Array(0 ..< 16)
        let response = VNCDES.encryptChallenge(challenge, password: "s3cret")
        #expect(response.count == 16)
        #expect(response != challenge)
        #expect(VNCDES.encryptChallenge(challenge, password: "s3cret") == response, "deterministic")
        #expect(VNCDES.encryptChallenge(challenge, password: "s3cret!!!") != response, "the seventh and eighth characters key the cipher")
        #expect(VNCDES.encryptChallenge(challenge, password: "s3cret!!x") == VNCDES.encryptChallenge(challenge, password: "s3cret!!"), "only the first eight bytes of a password count")
        #expect(VNCDES.encryptChallenge(challenge, password: "other") != response)
    }
}
