import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

/// A local server that speaks the same carrier protocol as Cloudflare's edge: an
/// HTTP/1.1 WebSocket upgrade whose binary frames carry a raw TCP byte stream to an
/// origin service.
///
/// ## What this does and does not prove
///
/// It exercises the parts of the path that are protocol, not policy: the upgrade
/// request shape, the Access headers, client-side masking, fragmentation, ping/pong,
/// close handshake, and a complete SSH session running over the resulting byte stream.
/// It deliberately reproduces the edge's *failure* responses too, because those drive
/// the app's error handling.
///
/// It does **not** prove that Cloudflare Access authentication works. Nothing local
/// can: that requires a real account, a real identity provider and a real tunnel. See
/// `TEST_REPORT.md` for which claims rest on this harness and which rest on the live
/// end-to-end run.
public final class WebSocketCarrierTestServer: @unchecked Sendable {
    /// How the server should answer the next upgrade attempt.
    public enum Behaviour: Sendable {
        /// Upgrade and bridge to the origin.
        case bridge
        /// Answer 302 to the Access login page, as the edge does for an unauthenticated request.
        case redirectToAccessLogin
        /// Answer 403, as the edge does when a policy denies the identity.
        case forbidden
        /// Answer 502, as the edge does when the tunnel cannot reach the origin.
        case originUnreachable
        /// Answer 530, as the edge does when no tunnel is connected.
        case tunnelOffline
    }

    public struct Configuration: Sendable {
        /// Host and port of the origin the carrier bridges to.
        public var originHost: String
        public var originPort: Int
        /// When set, an upgrade without a matching `Cf-Access-Token` is rejected.
        public var requiredAccessToken: String?
        /// When set, an upgrade without matching service-token headers is rejected.
        public var requiredServiceToken: (id: String, secret: String)?
        public var behaviour: Behaviour

        public init(
            originHost: String = "127.0.0.1",
            originPort: Int,
            requiredAccessToken: String? = nil,
            requiredServiceToken: (id: String, secret: String)? = nil,
            behaviour: Behaviour = .bridge
        ) {
            self.originHost = originHost
            self.originPort = originPort
            self.requiredAccessToken = requiredAccessToken
            self.requiredServiceToken = requiredServiceToken
            self.behaviour = behaviour
        }
    }

    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel
    public let port: Int
    /// Headers seen on the most recent upgrade attempt, so tests can assert on what
    /// the client actually sent rather than on what it was asked to send.
    private let recorded = NIOLockedValueBox<[HTTPHeaders]>([])

    public init(configuration: Configuration) throws {
        group = MultiThreadedEventLoopGroup.singleton
        let recorded = self.recorded
        let group = self.group

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 32)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let upgrader = NIOWebSocketServerUpgrader(
                    maxFrameSize: 1 << 20,
                    shouldUpgrade: { channel, head in
                        recorded.withLockedValue { $0.append(head.headers) }
                        guard Self.shouldUpgrade(head: head, configuration: configuration) else {
                            return channel.eventLoop.makeSucceededFuture(nil)
                        }
                        return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
                    },
                    upgradePipelineHandler: { channel, _ in
                        // The rejection responder reads HTTP request parts. Once the
                        // upgrade succeeds those become WebSocket frames, so it has to
                        // leave the pipeline rather than simply stop being useful.
                        channel.pipeline.handler(type: RejectionResponder.self)
                            .flatMap { channel.pipeline.removeHandler($0) }
                            .flatMapError { _ in channel.eventLoop.makeSucceededVoidFuture() }
                            .flatMap {
                                channel.pipeline.addHandler(
                                    CarrierBridgeHandler(
                                        originHost: configuration.originHost,
                                        originPort: configuration.originPort,
                                        group: group
                                    )
                                )
                            }
                    }
                )
                return channel.pipeline.configureHTTPServerPipeline(
                    withServerUpgrade: (
                        upgraders: [upgrader],
                        completionHandler: { _ in }
                    )
                ).flatMap {
                    channel.pipeline.addHandler(RejectionResponder(configuration: configuration))
                }
            }

        channel = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
        guard let boundPort = channel.localAddress?.port else {
            throw CarrierTestServerError.didNotBind
        }
        port = boundPort
    }

    public func observedUpgradeHeaders() -> [HTTPHeaders] {
        recorded.withLockedValue { $0 }
    }

    public func shutDown() {
        try? channel.close().wait()
    }

    static func shouldUpgrade(head: HTTPRequestHead, configuration: Configuration) -> Bool {
        guard case .bridge = configuration.behaviour else { return false }
        if let required = configuration.requiredAccessToken {
            guard head.headers.first(name: "Cf-Access-Token") == required else { return false }
        }
        if let service = configuration.requiredServiceToken {
            guard head.headers.first(name: "Cf-Access-Client-Id") == service.id,
                  head.headers.first(name: "Cf-Access-Client-Secret") == service.secret
            else { return false }
        }
        return true
    }
}

public enum CarrierTestServerError: Error, Sendable {
    case didNotBind
}

/// Answers upgrade attempts that were refused, reproducing the edge's status codes.
final class RejectionResponder: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let configuration: WebSocketCarrierTestServer.Configuration

    init(configuration: WebSocketCarrierTestServer.Configuration) {
        self.configuration = configuration
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .end = unwrapInboundIn(data) else { return }

        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: "0")
        let status: HTTPResponseStatus

        switch configuration.behaviour {
        case .bridge:
            // Reached only when the credential check failed.
            status = .forbidden
        case .redirectToAccessLogin:
            status = .found
            headers.add(name: "Location", value: "https://team.cloudflareaccess.com/cdn-cgi/access/login/example.com")
        case .forbidden:
            status = .forbidden
        case .originUnreachable:
            status = .badGateway
        case .tunnelOffline:
            status = HTTPResponseStatus(statusCode: 530)
        }

        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            bound.value.close(promise: nil)
        }
    }
}

/// Bridges WebSocket binary frames to a TCP connection to the origin, in both
/// directions, exactly as the tunnel does.
final class CarrierBridgeHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let originHost: String
    private let originPort: Int
    private let group: EventLoopGroup
    private var originChannel: Channel?
    private var pending: [ByteBuffer] = []

    init(originHost: String, originPort: Int, group: EventLoopGroup) {
        self.originHost = originHost
        self.originPort = originPort
        self.group = group
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let clientChannel = context.channel
        let eventLoop = context.eventLoop
        let boundContext = NIOLoopBound(context, eventLoop: eventLoop)
        let boundSelf = NIOLoopBound(self, eventLoop: eventLoop)
        ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandler(OriginToWebSocketHandler(clientChannel: clientChannel))
            }
            .connect(host: originHost, port: originPort)
            .hop(to: eventLoop)
            .whenComplete { result in
                let handler = boundSelf.value
                switch result {
                case let .success(channel):
                    handler.originChannel = channel
                    for buffer in handler.pending {
                        channel.writeAndFlush(buffer, promise: nil)
                    }
                    handler.pending.removeAll()
                case .failure:
                    boundContext.value.close(promise: nil)
                }
            }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .binary, .text, .continuation:
            var payload = frame.unmaskedData
            guard let bytes = payload.readSlice(length: payload.readableBytes), bytes.readableBytes > 0 else { return }
            if let originChannel {
                originChannel.writeAndFlush(bytes, promise: nil)
            } else {
                pending.append(bytes)
            }
        case .ping:
            var payload = frame.unmaskedData
            let echo = payload.readSlice(length: payload.readableBytes) ?? context.channel.allocator.buffer(capacity: 0)
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .pong, data: echo)), promise: nil)
        case .connectionClose:
            originChannel?.close(promise: nil)
            context.close(promise: nil)
        default:
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        originChannel?.close(promise: nil)
        context.fireChannelInactive()
    }
}

/// Wraps origin bytes back into binary frames.
final class OriginToWebSocketHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let clientChannel: Channel

    init(clientChannel: Channel) {
        self.clientChannel = clientChannel
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        // Server-to-client frames are unmasked, per RFC 6455.
        let frame = WebSocketFrame(fin: true, opcode: .binary, data: buffer)
        clientChannel.writeAndFlush(frame, promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        var payload = clientChannel.allocator.buffer(capacity: 2)
        payload.write(webSocketErrorCode: .normalClosure)
        let frame = WebSocketFrame(fin: true, opcode: .connectionClose, data: payload)
        let channel = clientChannel
        clientChannel.writeAndFlush(frame).whenComplete { _ in
            channel.close(promise: nil)
        }
        context.fireChannelInactive()
    }
}
