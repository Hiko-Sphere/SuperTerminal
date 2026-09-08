import Foundation
import NIOCore
import NIOPosix

/// A TCP server that sends back what it is given, and can be asked what it received.
///
/// The far end of every forward in these tests. It is a real listening socket on the real
/// loopback interface, so "the bytes arrived" is a fact about the network rather than
/// about this test's own bookkeeping.
final class EchoServer: @unchecked Sendable {
    private let group: EventLoopGroup
    private var channel: Channel?
    private(set) var port: Int = 0
    /// Prefix sent to every client the moment it connects, for the case that matters most
    /// to a forward: a service that speaks first.
    private let greeting: String?

    init(group: EventLoopGroup, greeting: String? = nil) {
        self.group = group
        self.greeting = greeting
    }

    func start() async throws {
        let greeting = greeting
        // Away from the ephemeral range; see `TestPorts`.
        port = try await TestPorts.bind { candidate in
            self.channel = try await ServerBootstrap(group: self.group)
                .childChannelInitializer { child in
                    child.pipeline.addHandler(EchoHandler(greeting: greeting))
                }
                .bind(host: "127.0.0.1", port: candidate)
                .get()
        }
    }

    func stop() async {
        try? await channel?.close().get()
        channel = nil
    }
}

private final class EchoHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let greeting: String?

    init(greeting: String?) {
        self.greeting = greeting
    }

    func channelActive(context: ChannelHandlerContext) {
        guard let greeting else { return }
        var buffer = context.channel.allocator.buffer(capacity: greeting.utf8.count)
        buffer.writeString(greeting)
        context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.write(data, promise: nil)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
    }
}

/// A plain TCP client that collects everything it is sent, for asserting on.
final class CollectingClient: @unchecked Sendable {
    private let group: EventLoopGroup
    private var channel: Channel?
    private let collector = Collector()

    init(group: EventLoopGroup) {
        self.group = group
    }

    func connect(host: String, port: Int) async throws {
        let collector = collector
        channel = try await ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandler(CollectingHandler(collector: collector))
            }
            .connect(host: host, port: port)
            .get()
    }

    func send(_ bytes: [UInt8]) async throws {
        guard let channel else { throw ChannelError.alreadyClosed }
        var buffer = channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        try await channel.writeAndFlush(buffer).get()
    }

    /// Waits until at least `count` bytes have arrived, or gives up.
    func received(atLeast count: Int, timeout: Duration = .seconds(10)) async throws -> [UInt8] {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let bytes = collector.bytes
            if bytes.count >= count { return bytes }
            try await Task.sleep(for: .milliseconds(10))
        }
        return collector.bytes
    }

    func close() async {
        try? await channel?.close().get()
        channel = nil
    }
}

final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UInt8] = []

    var bytes: [UInt8] { lock.withLock { storage } }

    func append(_ new: [UInt8]) { lock.withLock { storage.append(contentsOf: new) } }
}

private final class CollectingHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let collector: Collector

    init(collector: Collector) {
        self.collector = collector
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        collector.append(buffer.readBytes(length: buffer.readableBytes) ?? [])
    }
}
