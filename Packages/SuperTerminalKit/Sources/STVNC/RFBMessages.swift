import Foundation
import NIOCore

/// The RFB protocol as the client speaks it (RFC 6143, versions 3.3, 3.7 and 3.8).
/// Everything here is bytes in and bytes out; nothing touches a socket.
public enum RFB {
    public static let clientVersion = "RFB 003.008\n"

    /// The security types the client knows. "No authentication" has its own name because
    /// a case called `none`, reached through `init?(rawValue:)`, is matched by `case .none`
    /// as the optional's nil — and the real one is then never chosen.
    public enum SecurityType: UInt8, Sendable {
        case invalid = 0, noAuthentication = 1, vncAuthentication = 2, veNCrypt = 19
        /// What macOS Screen Sharing offers: a Diffie-Hellman exchange authenticating a
        /// macOS account, so a user name as well as a password (D-031).
        case appleRemoteDesktop = 30
    }

    /// The sub-types VeNCrypt (security type 19) multiplexes. Only the two that need no
    /// TLS layer of their own are usable here; the rest are named so that a server
    /// offering nothing else can say so.
    public enum VeNCryptSubtype: UInt32, Sendable {
        case plain = 256, vncAuthentication = 257
        case tlsNone = 258, tlsVNC = 259, tlsPlain = 260
        case x509None = 261, x509VNC = 262, x509Plain = 263

        var needsTLS: Bool { rawValue >= 258 }
    }

    /// Which security type to answer with, given what the server offered and what the
    /// user actually supplied. Pure, so the choice can be tested without a server.
    ///
    /// `None` wins whenever it is offered: the server is saying it wants no secret, and
    /// choosing anything else would demand one the user does not have. After that the
    /// order is by how well the password is protected — Apple's exchange encrypts it,
    /// classic VNC authentication hashes a challenge, and VeNCrypt's usable sub-types
    /// come last because one of them sends it in the clear.
    public static func chooseSecurity(
        offered: [UInt8],
        hasUsername: Bool,
        hasPassword: Bool
    ) throws -> UInt8 {
        if offered.contains(SecurityType.noAuthentication.rawValue) { return SecurityType.noAuthentication.rawValue }
        if offered.contains(SecurityType.appleRemoteDesktop.rawValue), hasUsername, hasPassword {
            return SecurityType.appleRemoteDesktop.rawValue
        }
        if offered.contains(SecurityType.vncAuthentication.rawValue), hasPassword {
            return SecurityType.vncAuthentication.rawValue
        }
        if offered.contains(SecurityType.veNCrypt.rawValue) { return SecurityType.veNCrypt.rawValue }
        // Everything the server would accept needs a credential that was not given. Which
        // one is missing decides the error, because a missing password is asked for on the
        // spot and a missing user name has to be edited into the screen.
        if offered.contains(SecurityType.appleRemoteDesktop.rawValue) {
            throw hasUsername ? VNCError.passwordRequired : VNCError.credentialsRequired
        }
        if offered.contains(SecurityType.vncAuthentication.rawValue) { throw VNCError.passwordRequired }
        throw VNCError.noAcceptableSecurity(offered)
    }

    public enum ClientMessage: UInt8 {
        case setPixelFormat = 0, setEncodings = 2, framebufferUpdateRequest = 3
        case keyEvent = 4, pointerEvent = 5, clientCutText = 6
    }

    public enum ServerMessage: UInt8 {
        case framebufferUpdate = 0, setColourMapEntries = 1, bell = 2, serverCutText = 3
    }

    public enum Encoding: Int32, Sendable {
        case raw = 0, copyRect = 1, rre = 2, hextile = 5, zrle = 16
        case cursor = -239, desktopSize = -223
        /// What the client asks for, in order of preference. Cursor is deliberately
        /// absent: with it the server stops painting its pointer into the framebuffer and
        /// expects the client to draw one — which a touch user, with no local pointer,
        /// would then never see.
        public static let preferred: [Encoding] = [.zrle, .hextile, .rre, .copyRect, .raw, .desktopSize]
    }

    /// 32-bit true colour, little-endian, B/G/R in the low three bytes — what the
    /// renderer draws directly, so every decoder writes pixels without conversion.
    public struct PixelFormat: Sendable, Equatable {
        public var bitsPerPixel: UInt8 = 32
        public var depth: UInt8 = 24
        public var bigEndian: Bool = false
        public var trueColour: Bool = true
        public var redMax: UInt16 = 255, greenMax: UInt16 = 255, blueMax: UInt16 = 255
        public var redShift: UInt8 = 16, greenShift: UInt8 = 8, blueShift: UInt8 = 0

        public static let client = PixelFormat()

        func write(into buffer: inout ByteBuffer) {
            buffer.writeInteger(bitsPerPixel)
            buffer.writeInteger(depth)
            buffer.writeInteger(UInt8(bigEndian ? 1 : 0))
            buffer.writeInteger(UInt8(trueColour ? 1 : 0))
            buffer.writeInteger(redMax); buffer.writeInteger(greenMax); buffer.writeInteger(blueMax)
            buffer.writeInteger(redShift); buffer.writeInteger(greenShift); buffer.writeInteger(blueShift)
            buffer.writeRepeatingByte(0, count: 3)
        }

        static func read(from buffer: inout ByteBuffer) -> PixelFormat? {
            guard buffer.readableBytes >= 16,
                  let bpp: UInt8 = buffer.readInteger(), let depth: UInt8 = buffer.readInteger(),
                  let bigEndian: UInt8 = buffer.readInteger(), let trueColour: UInt8 = buffer.readInteger(),
                  let redMax: UInt16 = buffer.readInteger(), let greenMax: UInt16 = buffer.readInteger(),
                  let blueMax: UInt16 = buffer.readInteger(),
                  let redShift: UInt8 = buffer.readInteger(), let greenShift: UInt8 = buffer.readInteger(),
                  let blueShift: UInt8 = buffer.readInteger() else { return nil }
            buffer.moveReaderIndex(forwardBy: 3)
            return PixelFormat(bitsPerPixel: bpp, depth: depth, bigEndian: bigEndian != 0, trueColour: trueColour != 0,
                               redMax: redMax, greenMax: greenMax, blueMax: blueMax,
                               redShift: redShift, greenShift: greenShift, blueShift: blueShift)
        }
    }

    public struct ServerInit: Sendable, Equatable {
        public var width: Int
        public var height: Int
        public var pixelFormat: PixelFormat
        public var name: String
    }

    public struct Rectangle: Sendable, Equatable {
        public var x: Int, y: Int, width: Int, height: Int
        public var encoding: Int32
    }

    // MARK: - Client messages

    public static func setPixelFormat(_ format: PixelFormat, into buffer: inout ByteBuffer) {
        buffer.writeInteger(ClientMessage.setPixelFormat.rawValue)
        buffer.writeRepeatingByte(0, count: 3)
        format.write(into: &buffer)
    }

    public static func setEncodings(_ encodings: [Encoding], into buffer: inout ByteBuffer) {
        buffer.writeInteger(ClientMessage.setEncodings.rawValue)
        buffer.writeInteger(UInt8(0))
        buffer.writeInteger(UInt16(encodings.count))
        for encoding in encodings { buffer.writeInteger(encoding.rawValue) }
    }

    public static func framebufferUpdateRequest(incremental: Bool, x: Int, y: Int, width: Int, height: Int, into buffer: inout ByteBuffer) {
        buffer.writeInteger(ClientMessage.framebufferUpdateRequest.rawValue)
        buffer.writeInteger(UInt8(incremental ? 1 : 0))
        buffer.writeInteger(UInt16(x)); buffer.writeInteger(UInt16(y))
        buffer.writeInteger(UInt16(width)); buffer.writeInteger(UInt16(height))
    }

    public static func keyEvent(keysym: UInt32, down: Bool, into buffer: inout ByteBuffer) {
        buffer.writeInteger(ClientMessage.keyEvent.rawValue)
        buffer.writeInteger(UInt8(down ? 1 : 0))
        buffer.writeRepeatingByte(0, count: 2)
        buffer.writeInteger(keysym)
    }

    /// `buttons` is the RFB mask: bit 0 left, 1 middle, 2 right, 3/4 wheel up/down, 5/6 wheel left/right.
    public static func pointerEvent(buttons: UInt8, x: Int, y: Int, into buffer: inout ByteBuffer) {
        buffer.writeInteger(ClientMessage.pointerEvent.rawValue)
        buffer.writeInteger(buttons)
        buffer.writeInteger(UInt16(clamping: x)); buffer.writeInteger(UInt16(clamping: y))
    }

    public static func clientCutText(_ text: String, into buffer: inout ByteBuffer) {
        // RFB cut text is Latin-1; characters outside it are replaced, never dropped silently.
        let latin1 = text.map { $0.unicodeScalars.first.map { $0.value < 256 ? UInt8($0.value) : UInt8(ascii: "?") } ?? UInt8(ascii: "?") }
        buffer.writeInteger(ClientMessage.clientCutText.rawValue)
        buffer.writeRepeatingByte(0, count: 3)
        buffer.writeInteger(UInt32(latin1.count))
        buffer.writeBytes(latin1)
    }

    // MARK: - Handshake parsing

    /// The server's version string, e.g. `RFB 003.008\n`; nil until 12 bytes are present.
    public static func readVersion(from buffer: inout ByteBuffer) -> (major: Int, minor: Int)? {
        guard buffer.readableBytes >= 12, let text = buffer.getString(at: buffer.readerIndex, length: 12) else { return nil }
        guard text.hasPrefix("RFB "), let major = Int(text.dropFirst(4).prefix(3)), let minor = Int(text.dropFirst(8).prefix(3)) else { return nil }
        buffer.moveReaderIndex(forwardBy: 12)
        return (major, minor)
    }

    /// Reads a length-prefixed reason string (used after a failed handshake).
    public static func readReason(from buffer: inout ByteBuffer) -> String? {
        guard let length: UInt32 = buffer.getInteger(at: buffer.readerIndex), buffer.readableBytes >= 4 + Int(length) else { return nil }
        buffer.moveReaderIndex(forwardBy: 4)
        return buffer.readString(length: Int(length))
    }

    public static func readServerInit(from buffer: inout ByteBuffer) -> ServerInit? {
        guard buffer.readableBytes >= 24, let width: UInt16 = buffer.getInteger(at: buffer.readerIndex),
              let height: UInt16 = buffer.getInteger(at: buffer.readerIndex + 2),
              let nameLength: UInt32 = buffer.getInteger(at: buffer.readerIndex + 20),
              buffer.readableBytes >= 24 + Int(nameLength) else { return nil }
        buffer.moveReaderIndex(forwardBy: 4)
        guard let format = PixelFormat.read(from: &buffer) else { return nil }
        buffer.moveReaderIndex(forwardBy: 4)
        let name = buffer.readString(length: Int(nameLength)) ?? ""
        return ServerInit(width: Int(width), height: Int(height), pixelFormat: format, name: name)
    }
}
