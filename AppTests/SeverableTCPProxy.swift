import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

/// A TCP relay in front of a real server, whose connections can be cut on demand.
///
/// Reconnection cannot be tested honestly without a connection that really dies. Faking
/// the drop — setting the session's state by hand, or throwing from a stubbed transport —
/// proves the state machine and nothing about whether a socket closing halfway through a
/// session is noticed, whether the SSH layer surfaces it, or whether what comes back is a
/// working shell.
///
/// So the traffic is real: a real `sshd` on the far side, a real handshake through this
/// relay, and ``sever()`` closes the sockets underneath it exactly as a network going away
/// would. ``allowConnections`` refuses new ones as well, which is what a server that has
/// not come back yet looks like.
public final class SeverableTCPProxy: @unchecked Sendable {
    private let group: EventLoopGroup
    private let ownsGroup: Bool
    private let originHost: String
    private let originPort: Int

    private let lock = NIOLock()
    private var channels: [Channel] = []
    private var serverChannel: Channel?
    private var _allowConnections = true

    public private(set) var port: Int = 0

    /// Whether new connections are accepted. Set to `false` to look like a server that is
    /// down; back to `true` to let a retry succeed.
    public var allowConnections: Bool {
        get { lock.withLock { _allowConnections } }
        set { lock.withLock { _allowConnections = newValue } }
    }

    public init(originHost: String, originPort: Int, group: EventLoopGroup? = nil) {
        self.originHost = originHost
        self.originPort = originPort
        if let group {
            self.group = group
            ownsGroup = false
        } else {
            self.group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
            ownsGroup = true
        }
    }

    public func start() async throws {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 32)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [weak self] channel in
                guard let self else { return channel.close() }
                guard allowConnections else { return channel.close() }
                record(channel)
                return connectOrigin(for: channel)
            }
        let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        serverChannel = channel
        port = channel.localAddress?.port ?? 0
    }

    /// Closes every connection currently open through the relay.
    ///
    /// What a session sees is what it would see if the network vanished: reads stop and
    /// the socket goes away, with no SSH disconnect message to explain it.
    public func sever() {
        let open = lock.withLock {
            let current = channels
            channels = []
            return current
        }
        for channel in open {
            channel.close(mode: .all, promise: nil)
        }
    }

    public func shutdown() async {
        sever()
        try? await serverChannel?.close().get()
        serverChannel = nil
        if ownsGroup { try? await group.shutdownGracefully() }
    }

    private func record(_ channel: Channel) {
        lock.withLock { channels.append(channel) }
        channel.closeFuture.whenComplete { [weak self] _ in
            self?.lock.withLock { self?.channels.removeAll { $0 === channel } }
        }
    }

    private func connectOrigin(for inbound: Channel) -> EventLoopFuture<Void> {
        ClientBootstrap(group: inbound.eventLoop)
            .connect(host: originHost, port: originPort)
            .flatMap { [weak self] outbound in
                guard let self else { return inbound.close() }
                record(outbound)
                let a = inbound.pipeline.addHandler(RelayHandler(peer: outbound))
                let b = outbound.pipeline.addHandler(RelayHandler(peer: inbound))
                return a.and(b).map { _ in }
            }
            .flatMapError { _ in inbound.close() }
    }
}

/// Copies bytes one way and closes the other side when this one ends.
private final class RelayHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let peer: Channel

    init(peer: Channel) { self.peer = peer }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        peer.writeAndFlush(data, promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        peer.close(mode: .all, promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        peer.close(mode: .all, promise: nil)
        context.close(promise: nil)
    }
}
