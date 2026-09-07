import NIOCore
import NIOWebSocket
import STCore

/// Adapts a WebSocket frame stream to the raw byte stream the SSH layer expects.
///
/// Cloudflare's Access carrier uses WebSocket purely as a framing envelope: every
/// binary frame's payload is the next run of TCP bytes for the origin service, and
/// message boundaries carry no meaning. This handler therefore forwards data payloads
/// as they arrive — including continuation fragments — rather than buffering a whole
/// message first. That keeps latency low for interactive typing and, more importantly,
/// removes the unbounded reassembly buffer that a hostile or broken peer could grow by
/// sending an endless fragmented message.
/// NIO calls a handler only on its own event loop, and every stored property here is
/// touched exclusively from those callbacks, so `@unchecked Sendable` states an
/// invariant the framework already guarantees rather than waiving a real check.
final class WebSocketByteStreamHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = WebSocketFrame

    private enum State {
        case open
        case closing
        case closed
    }

    private var state: State = .open
    private let log: STLogger
    private let pingInterval: TimeAmount
    private var pingTask: RepeatedTask?
    private var awaitingPong = false

    init(log: STLogger, pingInterval: TimeAmount = .seconds(30)) {
        self.log = log.child(subsystem: "cloudflare.ws")
        self.pingInterval = pingInterval
    }

    func handlerAdded(context: ChannelHandlerContext) {
        guard pingInterval.nanoseconds > 0 else { return }
        // Pings do double duty: they stop the edge retiring an idle tunnel, and an
        // unanswered ping is how a connection that died without a close frame — a
        // phone changing network, a sleeping laptop — is detected promptly.
        let boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        let boundSelf = NIOLoopBound(self, eventLoop: context.eventLoop)
        pingTask = context.eventLoop.scheduleRepeatedTask(
            initialDelay: pingInterval,
            delay: pingInterval
        ) { _ in
            let handler = boundSelf.value
            let context = boundContext.value
            guard handler.state == .open else { return }
            if handler.awaitingPong {
                handler.log.warning("no pong within the ping interval; closing the carrier")
                context.close(promise: nil)
                return
            }
            handler.awaitingPong = true
            let frame = WebSocketFrame(
                fin: true,
                opcode: .ping,
                maskKey: .random(),
                data: context.channel.allocator.buffer(capacity: 0)
            )
            context.writeAndFlush(handler.wrapOutboundOut(frame), promise: nil)
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        state = .closed
        pingTask?.cancel()
        pingTask = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)

        switch frame.opcode {
        case .binary, .text, .continuation:
            guard state == .open else { return }
            var payload = frame.unmaskedData
            if payload.readableBytes > 0, let bytes = payload.readSlice(length: payload.readableBytes) {
                context.fireChannelRead(wrapInboundOut(bytes))
            }

        case .ping:
            guard state == .open else { return }
            // RFC 6455 §5.5.2: a pong must carry the ping's application data.
            var payload = frame.unmaskedData
            let echo = payload.readSlice(length: payload.readableBytes) ?? context.channel.allocator.buffer(capacity: 0)
            let pong = WebSocketFrame(fin: true, opcode: .pong, maskKey: .random(), data: echo)
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)

        case .pong:
            awaitingPong = false

        case .connectionClose:
            handlePeerClose(context: context, frame: frame)

        default:
            log.warning("unexpected WebSocket opcode", ["opcode": "\(frame.opcode)"])
            close(context: context, code: .protocolError, promise: nil)
        }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        guard state == .open else {
            promise?.fail(ChannelError.ioOnClosedChannel)
            return
        }
        let buffer = unwrapOutboundIn(data)
        guard buffer.readableBytes > 0 else {
            promise?.succeed(())
            return
        }
        // RFC 6455 §5.3: every client-to-server frame must be masked.
        let frame = WebSocketFrame(fin: true, opcode: .binary, maskKey: .random(), data: buffer)
        context.write(wrapOutboundOut(frame), promise: promise)
    }

    func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        guard mode == .all else {
            // Half-closure has no meaning over WebSocket; refuse rather than pretend.
            promise?.fail(ChannelError.operationUnsupported)
            return
        }
        close(context: context, code: .normalClosure, promise: promise)
    }

    private func close(context: ChannelHandlerContext, code: WebSocketErrorCode, promise: EventLoopPromise<Void>?) {
        guard state == .open else {
            promise?.succeed(())
            return
        }
        state = .closing
        var payload = context.channel.allocator.buffer(capacity: 2)
        payload.write(webSocketErrorCode: code)
        let frame = WebSocketFrame(fin: true, opcode: .connectionClose, maskKey: .random(), data: payload)
        let boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        context.writeAndFlush(wrapOutboundOut(frame)).whenComplete { _ in
            boundContext.value.close(mode: .all, promise: promise)
        }
    }

    private func handlePeerClose(context: ChannelHandlerContext, frame: WebSocketFrame) {
        switch state {
        case .closed:
            return
        case .closing:
            state = .closed
            context.close(promise: nil)
        case .open:
            state = .closing
            // Echo the peer's status code back, per RFC 6455 §5.5.1.
            var data = frame.unmaskedData
            let closeCode = data.readWebSocketErrorCode() ?? .normalClosure
            var payload = context.channel.allocator.buffer(capacity: 2)
            payload.write(webSocketErrorCode: closeCode)
            let reply = WebSocketFrame(fin: true, opcode: .connectionClose, maskKey: .random(), data: payload)
            let boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
            let boundSelf = NIOLoopBound(self, eventLoop: context.eventLoop)
            context.writeAndFlush(wrapOutboundOut(reply)).whenComplete { _ in
                boundSelf.value.state = .closed
                boundContext.value.close(promise: nil)
            }
        }
    }
}
