import Foundation
import NIOCore
import NIOEmbedded
import Testing
@testable import STVNC

/// What a frame costs when it arrives the way a frame actually arrives (D-030).
///
/// A 1080p update is eight megabytes and reaches the client in a few hundred TCP segments,
/// none of which completes the rectangle on its own. Anything the client does *per read*
/// that touches the whole accumulated buffer therefore happens hundreds of times per
/// frame, and the cost is quadratic in the frame size — invisible to a test that hands the
/// decoder one complete buffer, and the difference between a usable screen and a slideshow.
@Suite("RFB receive path", .serialized)
struct RFBReceiveTests {
    private static let width = 1920
    private static let height = 1080

    /// A channel with the handshake already played out, ready for framebuffer updates.
    private func connectedChannel() throws -> (EmbeddedChannel, RFBFramebuffer) {
        let framebuffer = RFBFramebuffer(width: 1, height: 1)
        let (events, continuation) = AsyncStream<VNCEvent>.makeStream(bufferingPolicy: .unbounded)
        _ = events
        let channel = EmbeddedChannel()
        let ready = channel.eventLoop.makePromise(of: RFB.ServerInit.self)
        let handler = RFBClientHandler(
            options: .init(),
            framebuffer: framebuffer,
            events: continuation,
            ready: ready
        )
        try channel.pipeline.syncOperations.addHandler(handler)

        var server = ByteBuffer()
        server.writeString("RFB 003.008\n")
        server.writeInteger(UInt8(1))                  // one security type
        server.writeInteger(UInt8(1))                  // …which is None
        server.writeInteger(UInt32(0))                 // SecurityResult: OK
        server.writeInteger(UInt16(Self.width))
        server.writeInteger(UInt16(Self.height))
        RFB.PixelFormat.client.write(into: &server)
        server.writeInteger(UInt32(4))
        server.writeString("desk")
        try channel.writeInbound(server)
        // Everything the client wrote back during the handshake.
        while try channel.readOutbound(as: ByteBuffer.self) != nil {}
        return (channel, framebuffer)
    }

    /// One full-screen Raw update, as bytes on the wire.
    private func rawUpdate() -> [UInt8] {
        var update = ByteBuffer()
        update.writeInteger(UInt8(0))                  // FramebufferUpdate
        update.writeInteger(UInt8(0))                  // padding
        update.writeInteger(UInt16(1))                 // one rectangle
        update.writeInteger(UInt16(0)); update.writeInteger(UInt16(0))
        update.writeInteger(UInt16(Self.width)); update.writeInteger(UInt16(Self.height))
        update.writeInteger(Int32(RFB.Encoding.raw.rawValue))
        update.writeBytes([UInt8](repeating: 0x40, count: Self.width * Self.height * 4))
        return Array(update.readableBytesView)
    }

    private func feed(_ bytes: [UInt8], to channel: EmbeddedChannel, chunk: Int) throws {
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + chunk, bytes.count)
            try channel.writeInbound(ByteBuffer(bytes: bytes[offset ..< end]))
            while try channel.readOutbound(as: ByteBuffer.self) != nil {}
            offset = end
        }
    }

    private func seconds(_ body: () throws -> Void) rethrows -> Double {
        let start = ContinuousClock.now
        try body()
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    @Test("A frame split across the network costs about what the same frame costs whole")
    func segmentedFrameIsNotQuadratic() throws {
        let bytes = rawUpdate()

        let (whole, wholeBuffer) = try connectedChannel()
        let wholeSeconds = try seconds { try feed(bytes, to: whole, chunk: bytes.count) }
        #expect(wholeBuffer.pixel(x: 10, y: 10) == (0x40, 0x40, 0x40), "the frame was decoded")
        _ = try whole.finish()

        // 16 KB is a realistic segment for a TLS-wrapped stream; a 960×540 frame is two
        // megabytes, so this is well over a hundred reads for one frame.
        let (split, splitBuffer) = try connectedChannel()
        let splitSeconds = try seconds { try feed(bytes, to: split, chunk: 16 * 1024) }
        #expect(splitBuffer.pixel(x: 10, y: 10) == (0x40, 0x40, 0x40), "and so was this one")
        _ = try split.finish()

        // Arriving in pieces costs a little more — more calls, more bookkeeping — but it
        // must not cost a multiple. Compacting the buffer after every read made this ratio
        // grow with the square of the frame, which is what made a full-screen update crawl.
        let ratio = splitSeconds / max(wholeSeconds, 0.000_001)
        #expect(ratio < 4, "a segmented frame took \(String(format: "%.1f", ratio))× a whole one (\(Int(splitSeconds * 1000))ms vs \(Int(wholeSeconds * 1000))ms)")
    }

    @Test("A frame that has not all arrived is left alone until it has, and then decoded once")
    func partialRectangleWaits() throws {
        let bytes = rawUpdate()
        let (channel, framebuffer) = try connectedChannel()
        defer { _ = try? channel.finish() }

        // Everything but the last byte: nothing may be drawn yet.
        try feed(Array(bytes.dropLast()), to: channel, chunk: 32 * 1024)
        #expect(framebuffer.pixel(x: 10, y: 10) == (0, 0, 0), "an incomplete rectangle is not half-drawn")

        try channel.writeInbound(ByteBuffer(bytes: [bytes[bytes.count - 1]]))
        #expect(framebuffer.pixel(x: 10, y: 10) == (0x40, 0x40, 0x40), "and is drawn as soon as it is whole")
    }
}
