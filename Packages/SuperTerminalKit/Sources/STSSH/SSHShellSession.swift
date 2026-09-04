import Foundation
import NIOCore
import NIOSSH
import STCore

/// Bridges an SSH child channel's data and control events into an `AsyncStream`.
///
/// `@unchecked Sendable` is correct here rather than a shortcut: every stored property
/// is either immutable or an `AsyncStream.Continuation`, which is itself thread-safe,
/// and NIO only ever calls this handler on its channel's event loop.
///
/// Back-pressure note: the stream buffers without bound because the consumer is the
/// terminal emulator, which parses far faster than a network link delivers. The real
/// bound on memory is the emulator's scrollback limit, not this buffer.
final class SSHChannelDataHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    private let continuation: AsyncStream<SSHChannelEvent>.Continuation

    init(continuation: AsyncStream<SSHChannelEvent>.Continuation) {
        self.continuation = continuation
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case let .byteBuffer(buffer) = channelData.data else { return }
        let bytes = Data(buffer.readableBytesView)
        guard !bytes.isEmpty else { return }
        switch channelData.type {
        case .channel:
            continuation.yield(.output(bytes))
        case .stdErr:
            continuation.yield(.errorOutput(bytes))
        default:
            // Unknown extended data types are dropped rather than mixed into stdout,
            // where they would corrupt the terminal stream.
            break
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let status = event as? SSHChannelRequestEvent.ExitStatus {
            continuation.yield(.exit(status.exitStatus))
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        continuation.yield(.closed)
        continuation.finish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        continuation.yield(.closed)
        continuation.finish()
        context.close(promise: nil)
    }
}

/// An interactive shell running on the remote host.
public actor SSHShellSession {
    private let channel: Channel
    private let log: STLogger
    private var currentSize: TerminalSize = .default
    private var isClosed = false

    /// Everything the remote shell writes, in order.
    public nonisolated let output: AsyncStream<SSHChannelEvent>

    init(channel: Channel, output: AsyncStream<SSHChannelEvent>, log: STLogger) {
        self.channel = channel
        self.output = output
        self.log = log.child(subsystem: "ssh.shell")
    }

    /// Sends bytes to the remote shell's standard input.
    public func send(_ data: Data) async throws {
        guard !isClosed, channel.isActive else {
            throw STError(
                category: .sshChannel,
                message: "The session is no longer connected.",
                recoverySuggestion: "Reconnect to continue."
            )
        }
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        let payload = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
        try await channel.writeAndFlush(payload).get()
    }

    public func send(_ text: String) async throws {
        try await send(Data(text.utf8))
    }

    /// Tells the remote side the terminal was resized.
    ///
    /// Without this, full-screen programs keep drawing at the old geometry after a
    /// rotation, a Split View change or a Stage Manager resize — which on iPad is the
    /// normal case, not an edge case.
    public func resize(to size: TerminalSize) async throws {
        guard size != currentSize else { return }
        guard !isClosed, channel.isActive else { return }
        currentSize = size
        let event = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: size.columns,
            terminalRowHeight: size.rows,
            terminalPixelWidth: size.pixelWidth,
            terminalPixelHeight: size.pixelHeight
        )
        let promise = channel.eventLoop.makePromise(of: Void.self)
        channel.triggerUserOutboundEvent(event, promise: promise)
        try await promise.futureResult.get()
        log.debug("terminal resized", ["cols": "\(size.columns)", "rows": "\(size.rows)"])
    }

    /// Signals end-of-input without tearing down the connection.
    public func sendEOF() async throws {
        guard !isClosed, channel.isActive else { return }
        try await channel.close(mode: .output).get()
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        try? await channel.close().get()
    }

    public nonisolated var isActive: Bool { channel.isActive }
}
