import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix

/// A local HTTP server that speaks the chat-completions protocol the assistant's provider
/// client speaks: it answers `POST …/chat/completions` either with a streamed
/// `text/event-stream` body of the chunks it was given, or with a status and body of its
/// own. It records every request so a test can read the headers and body that actually
/// went over the wire — the key in one header and nowhere else, the stream flag, the
/// messages.
///
/// It is a real HTTP server on a real socket, not a stub inside `URLSession`; what it
/// proves is the client's wire behaviour, and only a real provider proves the rest.
public final class ChatCompletionsTestServer: @unchecked Sendable {
    public enum Behaviour: Sendable {
        /// Stream these text deltas as SSE chunks, then `[DONE]`.
        case stream([String])
        /// Answer with this status and body.
        case respond(status: Int, body: String)
    }

    public struct RecordedRequest: Sendable {
        public var method: String
        public var path: String
        public var headers: [(String, String)]
        public var body: String
    }

    public let port: Int
    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel
    private let behaviour: NIOLockedValueBox<Behaviour>
    private let requests = NIOLockedValueBox<[RecordedRequest]>([])

    public var recordedRequests: [RecordedRequest] { requests.withLockedValue { $0 } }
    public var baseURL: URL { URL(string: "http://127.0.0.1:\(port)/v1")! }

    public func set(_ behaviour: Behaviour) { self.behaviour.withLockedValue { $0 = behaviour } }

    public init(behaviour: Behaviour) throws {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let behaviourBox = NIOLockedValueBox(behaviour)
        self.behaviour = behaviourBox
        let requests = self.requests
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(Responder(behaviour: behaviourBox, requests: requests))
                }
            }
        channel = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
        port = channel.localAddress!.port!
    }

    public func shutDown() {
        try? channel.close().wait()
        try? group.syncShutdownGracefully()
    }

    private final class Responder: ChannelInboundHandler {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        private let behaviour: NIOLockedValueBox<Behaviour>
        private let requests: NIOLockedValueBox<[RecordedRequest]>
        private var head: HTTPRequestHead?
        private var body = ByteBuffer()

        init(behaviour: NIOLockedValueBox<Behaviour>, requests: NIOLockedValueBox<[RecordedRequest]>) {
            self.behaviour = behaviour
            self.requests = requests
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch unwrapInboundIn(data) {
            case let .head(head):
                self.head = head
                body = ByteBuffer()
            case var .body(part):
                body.writeBuffer(&part)
            case .end:
                guard let head else { return }
                let recorded = RecordedRequest(
                    method: head.method.rawValue,
                    path: head.uri,
                    headers: head.headers.map { ($0.name, $0.value) },
                    body: String(buffer: body)
                )
                requests.withLockedValue { $0.append(recorded) }
                respond(context: context, to: head)
                self.head = nil
            }
        }

        private func respond(context: ChannelHandlerContext, to request: HTTPRequestHead) {
            switch behaviour.withLockedValue({ $0 }) {
            case let .stream(deltas):
                var headers = HTTPHeaders()
                headers.add(name: "Content-Type", value: "text/event-stream")
                headers.add(name: "Cache-Control", value: "no-cache")
                headers.add(name: "Connection", value: "close")
                let responseHead = HTTPResponseHead(version: request.version, status: .ok, headers: headers)
                context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
                var text = "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}\n\n"
                for delta in deltas {
                    let escaped = delta
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "\"", with: "\\\"")
                        .replacingOccurrences(of: "\n", with: "\\n")
                    text += "data: {\"choices\":[{\"delta\":{\"content\":\"\(escaped)\"}}]}\n\n"
                }
                text += "data: [DONE]\n\n"
                var buffer = context.channel.allocator.buffer(capacity: text.utf8.count)
                buffer.writeString(text)
                context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in context.close(promise: nil) }
            case let .respond(status, body):
                var headers = HTTPHeaders()
                headers.add(name: "Content-Type", value: "application/json")
                headers.add(name: "Content-Length", value: "\(body.utf8.count)")
                headers.add(name: "Connection", value: "close")
                let responseHead = HTTPResponseHead(version: request.version, status: .init(statusCode: status), headers: headers)
                context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
                var buffer = context.channel.allocator.buffer(capacity: body.utf8.count)
                buffer.writeString(body)
                context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in context.close(promise: nil) }
            }
        }
    }
}
