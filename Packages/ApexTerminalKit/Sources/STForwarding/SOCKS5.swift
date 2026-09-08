import NIOCore
import STCore

/// The client half of a dynamic forward: SOCKS5, as RFC 1928 defines it, spoken to
/// whatever asked to use the proxy.
///
/// Only `CONNECT` is offered, and only without authentication. Both are deliberate. BIND
/// and UDP ASSOCIATE need the proxy to listen on the network for a peer to call back,
/// which is exactly the thing a forward on a phone must not do; and a password on a proxy
/// bound to `127.0.0.1` protects against nothing that reaching `127.0.0.1` has not already
/// defeated. A client asking for anything else is told so in the protocol's own terms
/// rather than left waiting.
enum SOCKS5Negotiation {
    static let version: UInt8 = 5
    static let noAuthentication: UInt8 = 0x00
    static let noAcceptableMethods: UInt8 = 0xFF
    static let connect: UInt8 = 0x01

    enum Reply: UInt8 {
        case success = 0x00
        case generalFailure = 0x01
        case commandNotSupported = 0x07
        case addressTypeNotSupported = 0x08
    }

    /// Reads the greeting and the request, and returns where the client wants to go.
    ///
    /// The handler stays in the pipeline afterwards, holding anything the client sent
    /// early, until ``replySuccess(on:)`` hands those bytes on.
    static func destination(on channel: Channel) async throws -> (host: String, port: Int) {
        let promise = channel.eventLoop.makePromise(of: SOCKS5Handler.Destination.self)
        try await channel.pipeline.addHandler(SOCKS5Handler(promise: promise)).get()
        // The handshake needs bytes, so reads start here rather than after the splice.
        // Nothing is lost by starting early: this handler holds anything that arrives
        // beyond the handshake until it hands the connection on.
        try await channel.setOption(ChannelOptions.autoRead, value: true).get()
        let destination = try await promise.futureResult.get()
        return (destination.host, destination.port)
    }

    /// Tells the client it is connected, then steps out of the way.
    static func replySuccess(on channel: Channel) async throws {
        try await withHandler(on: channel) { try await $0.reply(.success) }
    }

    /// Tells the client the connection failed, so it can report that instead of hanging.
    static func replyFailure(on channel: Channel) async throws {
        try await withHandler(on: channel) { try await $0.reply(.generalFailure) }
    }

    private static func withHandler(
        on channel: Channel,
        _ body: (SOCKS5Handler) async throws -> Void
    ) async throws {
        let handler = try await channel.pipeline.handler(type: SOCKS5Handler.self).get()
        try await body(handler)
    }
}

/// Parses one SOCKS5 conversation, then gets out of the way.
final class SOCKS5Handler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundOut = ByteBuffer

    struct Destination: Sendable {
        var host: String
        var port: Int
        /// Echoed back in the reply, because the protocol wants the address family it was
        /// given rather than one of the proxy's choosing.
        var addressType: UInt8
        var addressBytes: [UInt8]
    }

    private enum Stage {
        case greeting
        case request
        /// Parsed. Anything further is held until the reply is sent.
        case done
    }

    private var stage: Stage = .greeting
    /// Set the moment the handler starts stepping out of the pipeline. Removal is not
    /// instantaneous, and anything that arrives in between belongs to the tunnel — the
    /// first line of the request, usually. Dropping it looked exactly like a proxy that
    /// connects and then goes deaf.
    private var handedOff = false
    private var buffer: ByteBuffer?
    private var promise: EventLoopPromise<Destination>?
    private var destination: Destination?
    private var context: ChannelHandlerContext?

    init(promise: EventLoopPromise<Destination>) {
        self.promise = promise
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        buffer = context.channel.allocator.buffer(capacity: 512)
        // Reads are off — the listener turns them off before anything is spliced — so the
        // handshake has to ask for its own bytes.
        context.read()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        promise?.fail(ChannelError.alreadyClosed)
        promise = nil
    }

    func channelInactive(context: ChannelHandlerContext) {
        promise?.fail(ChannelError.eof)
        promise = nil
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if handedOff {
            context.fireChannelRead(data)
            return
        }
        var incoming = unwrapInboundIn(data)
        buffer?.writeBuffer(&incoming)
        advance(context: context)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        if handedOff { context.fireChannelReadComplete() }
    }

    private func advance(context: ChannelHandlerContext) {
        guard stage != .done else { return }
        while true {
            switch stage {
            case .greeting:
                guard let accepted = parseGreeting(context: context) else { context.read(); return }
                guard accepted else { return }
                stage = .request
            case .request:
                guard let parsed = parseRequest(context: context) else { context.read(); return }
                destination = parsed
                stage = .done
                promise?.succeed(parsed)
                promise = nil
                return
            case .done:
                return
            }
        }
    }

    /// `nil` means "not enough bytes yet"; `false` means the conversation is over.
    private func parseGreeting(context: ChannelHandlerContext) -> Bool? {
        guard var buffer, buffer.readableBytes >= 2 else { return nil }
        let peek = buffer.getBytes(at: buffer.readerIndex, length: 2)!
        guard peek[0] == SOCKS5Negotiation.version else {
            // Not SOCKS5 at all. Nothing to say that the client would understand.
            context.close(promise: nil)
            return false
        }
        let count = Int(peek[1])
        guard buffer.readableBytes >= 2 + count else { return nil }
        buffer.moveReaderIndex(forwardBy: 2)
        let methods = buffer.readBytes(length: count) ?? []
        self.buffer = buffer

        guard methods.contains(SOCKS5Negotiation.noAuthentication) else {
            write(bytes: [SOCKS5Negotiation.version, SOCKS5Negotiation.noAcceptableMethods], context: context, thenClose: true)
            return false
        }
        write(bytes: [SOCKS5Negotiation.version, SOCKS5Negotiation.noAuthentication], context: context, thenClose: false)
        return true
    }

    private func parseRequest(context: ChannelHandlerContext) -> Destination? {
        guard var buffer, buffer.readableBytes >= 5 else { return nil }
        let header = buffer.getBytes(at: buffer.readerIndex, length: 5)!
        guard header[0] == SOCKS5Negotiation.version else {
            context.close(promise: nil)
            return nil
        }
        guard header[1] == SOCKS5Negotiation.connect else {
            fail(.commandNotSupported, context: context)
            return nil
        }

        let addressType = header[3]
        let addressLength: Int
        switch addressType {
        case 0x01: addressLength = 4
        case 0x03: addressLength = 1 + Int(header[4])
        case 0x04: addressLength = 16
        default:
            fail(.addressTypeNotSupported, context: context)
            return nil
        }
        guard buffer.readableBytes >= 4 + addressLength + 2 else { return nil }

        buffer.moveReaderIndex(forwardBy: 4)
        let addressBytes = buffer.readBytes(length: addressLength) ?? []
        let port = Int(buffer.readInteger(as: UInt16.self) ?? 0)
        self.buffer = buffer

        let host: String
        switch addressType {
        case 0x01:
            host = addressBytes.map(String.init).joined(separator: ".")
        case 0x03:
            host = String(decoding: addressBytes.dropFirst(), as: UTF8.self)
        default:
            // IPv6, in the form the resolver on the other side will accept.
            host = stride(from: 0, to: 16, by: 2)
                .map { String(format: "%02x%02x", addressBytes[$0], addressBytes[$0 + 1]) }
                .joined(separator: ":")
        }
        return Destination(host: host, port: port, addressType: addressType, addressBytes: addressBytes)
    }

    // MARK: - Answering

    func reply(_ code: SOCKS5Negotiation.Reply) async throws {
        guard let context else { throw ChannelError.alreadyClosed }
        let destination = destination
        let promise = context.eventLoop.makePromise(of: Void.self)
        context.eventLoop.execute { [self] in
            var out = context.channel.allocator.buffer(capacity: 32)
            out.writeInteger(SOCKS5Negotiation.version)
            out.writeInteger(code.rawValue)
            out.writeInteger(UInt8(0))
            if let destination {
                out.writeInteger(destination.addressType)
                out.writeBytes(destination.addressBytes)
                out.writeInteger(UInt16(destination.port))
            } else {
                out.writeInteger(UInt8(0x01))
                out.writeBytes([0, 0, 0, 0])
                out.writeInteger(UInt16(0))
            }
            context.writeAndFlush(NIOAny(out)).whenComplete { result in
                switch result {
                case .success:
                    if code == .success {
                        self.handOffAndRemove(context: context)
                    } else {
                        context.close(promise: nil)
                    }
                    promise.succeed(())
                case let .failure(error):
                    promise.fail(error)
                }
            }
        }
        try await promise.futureResult.get()
    }

    /// Passes on anything the client sent before it was told to, then leaves.
    ///
    /// A client is not supposed to speak before the reply, but some do — and those bytes
    /// are the first line of the request the whole tunnel exists to carry.
    private func handOffAndRemove(context: ChannelHandlerContext) {
        handedOff = true
        if let buffer, buffer.readableBytes > 0 {
            context.fireChannelRead(wrapInboundOut(buffer))
            context.fireChannelReadComplete()
        }
        buffer = nil
        context.pipeline.syncOperations.removeHandler(context: context, promise: nil)
    }

    private func fail(_ code: SOCKS5Negotiation.Reply, context: ChannelHandlerContext) {
        var out = context.channel.allocator.buffer(capacity: 10)
        out.writeInteger(SOCKS5Negotiation.version)
        out.writeInteger(code.rawValue)
        out.writeInteger(UInt8(0))
        out.writeInteger(UInt8(0x01))
        out.writeBytes([0, 0, 0, 0])
        out.writeInteger(UInt16(0))
        context.writeAndFlush(NIOAny(out)).whenComplete { _ in context.close(promise: nil) }
        promise?.fail(STError(
            category: .configuration,
            message: String(localized: "The SOCKS client asked for something this proxy does not offer.", bundle: .module)
        ))
        promise = nil
    }

    private func write(bytes: [UInt8], context: ChannelHandlerContext, thenClose: Bool) {
        var out = context.channel.allocator.buffer(capacity: bytes.count)
        out.writeBytes(bytes)
        context.writeAndFlush(NIOAny(out)).whenComplete { _ in
            if thenClose { context.close(promise: nil) }
        }
    }
}
