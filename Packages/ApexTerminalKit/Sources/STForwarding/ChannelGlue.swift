import NIOConcurrencyHelpers
import NIOCore

/// Running totals for one rule, written from whichever event loop moved the bytes.
public final class TrafficCounter: @unchecked Sendable {
    private let lock = NIOLock()
    private var traffic = PortForwardTraffic()

    public init() {}

    public var snapshot: PortForwardTraffic { lock.withLock { traffic } }

    func addOutbound(_ bytes: Int) { lock.withLock { traffic.bytesOut += bytes } }
    func addInbound(_ bytes: Int) { lock.withLock { traffic.bytesIn += bytes } }

    func connectionOpened() {
        lock.withLock {
            traffic.openConnections += 1
            traffic.totalConnections += 1
        }
    }

    func connectionClosed() {
        lock.withLock { traffic.openConnections = max(0, traffic.openConnections - 1) }
    }

    func reset() { lock.withLock { traffic = PortForwardTraffic() } }
}

/// Joins two channels so that everything read on one is written to the other.
///
/// This is the piece that makes a forward a forward, and the reason it is not simply
/// "read, write" is backpressure. A phone on a slow link talking to a fast server will
/// otherwise buffer the whole difference in memory: reads are only re-enabled once the
/// other side has actually accepted what was sent, so a download through a forward is
/// paced by the slower of the two ends rather than by how fast the faster one can produce.
///
/// Half-closure is relayed rather than promoted to a full close, because a protocol that
/// says "I have finished sending, now tell me the answer" — which is most of them, HTTP
/// included — breaks if one direction closing takes the other down with it.
/// `@unchecked Sendable` because a handler is created on whatever task is setting up the
/// forward and then handed to exactly one channel, after which only that channel's event
/// loop ever touches it. The hand-off is the only crossing, and it happens once.
final class GlueHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false
    private let counter: TrafficCounter?
    /// Which direction this half counts as, so the two ends do not both report "out".
    private let countsAsOutbound: Bool

    private init(counter: TrafficCounter?, countsAsOutbound: Bool) {
        self.counter = counter
        self.countsAsOutbound = countsAsOutbound
    }

    /// A pair of handlers to install one in each channel.
    ///
    /// **Both channels must be on the same event loop.** Each half reads the other's
    /// writability directly, which NIO permits only within a loop and traps on otherwise —
    /// the callers arrange this by opening their end on the SSH connection's loop. `outbound` is the half that
    /// reads from the client side, so what it forwards is traffic leaving this device.
    static func pair(counter: TrafficCounter?) -> (outbound: GlueHandler, inbound: GlueHandler) {
        let first = GlueHandler(counter: counter, countsAsOutbound: true)
        let second = GlueHandler(counter: counter, countsAsOutbound: false)
        first.partner = second
        second.partner = first
        return (first, second)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        // The two halves are installed one after the other, and a channel that is already
        // reading will ask for its first read before the second half exists — finding no
        // partner to check for writability, and parking the request. Nothing would ever
        // wake it: writability never changes on a channel that was writable all along. So
        // arriving late is announced, and the other side releases what it was holding.
        partner?.partnerBecameWritable()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        if let counter {
            if countsAsOutbound { counter.addOutbound(buffer.readableBytes) }
            else { counter.addInbound(buffer.readableBytes) }
        }
        partner?.partnerWrite(buffer)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner?.partnerFlush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner?.partnerCloseFull()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event {
            // The peer will send no more. Tell the other side, and let it answer.
            partner?.partnerWriteEOF()
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        partner?.partnerCloseFull()
        context.close(promise: nil)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable { partner?.partnerBecameWritable() }
    }

    func read(context: ChannelHandlerContext) {
        if let partner, partner.partnerWritable {
            context.read()
        } else {
            pendingRead = true
        }
    }

    // MARK: - The other half's side of the conversation

    private var partnerWritable: Bool { context?.channel.isWritable ?? false }

    private func partnerWrite(_ buffer: ByteBuffer) {
        context?.write(wrapOutboundOut(buffer), promise: nil)
    }

    private func partnerFlush() {
        context?.flush()
    }

    private func partnerWriteEOF() {
        context?.close(mode: .output, promise: nil)
    }

    private func partnerCloseFull() {
        context?.close(promise: nil)
    }

    private func partnerBecameWritable() {
        if pendingRead {
            pendingRead = false
            context?.read()
        }
    }
}
