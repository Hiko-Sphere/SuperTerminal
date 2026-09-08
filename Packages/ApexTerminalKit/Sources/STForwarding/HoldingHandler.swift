import NIOCore

/// Holds what arrives until there is somewhere to put it.
///
/// A channel the server opens for a remote forward is active the moment it exists, and an
/// SSH child channel takes its `autoRead` from its parent when it activates — so switching
/// reads off in the initialiser does not stick. Meanwhile the other half of the forward is
/// a TCP connection that has to be made, which takes time. Whatever the server sends in
/// between has to go somewhere, and dropping it would corrupt exactly the protocols that
/// send something first.
///
/// So it is kept here, and handed on the moment the far end exists.
final class HoldingHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private var held: [ByteBuffer] = []
    private var closedWhileHolding = false
    private var released = false

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if released {
            context.fireChannelRead(data)
        } else {
            held.append(unwrapInboundIn(data))
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        if released { context.fireChannelReadComplete() }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if released {
            context.fireChannelInactive()
        } else {
            // Remembered rather than forwarded: the handler after this one does not exist
            // yet, and a close it never hears about would leave the other side open.
            closedWhileHolding = true
        }
    }

    /// Hands on everything held, in order, and steps out of the pipeline.
    func release(context: ChannelHandlerContext) {
        guard !released else { return }
        released = true
        for buffer in held {
            context.fireChannelRead(wrapInboundOut(buffer))
        }
        if !held.isEmpty { context.fireChannelReadComplete() }
        held = []
        if closedWhileHolding {
            context.fireChannelInactive()
            return
        }
        context.pipeline.syncOperations.removeHandler(context: context, promise: nil)
    }
}

extension Channel {
    /// Releases the holding handler, if one is installed.
    func releaseHeldReads() -> EventLoopFuture<Void> {
        pipeline.context(handlerType: HoldingHandler.self).flatMapThrowing { context in
            guard let handler = context.handler as? HoldingHandler else { return }
            handler.release(context: context)
        }.recover { _ in () }
    }
}
