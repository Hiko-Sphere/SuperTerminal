import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

/// What a VNC session reports to whoever draws it.
public enum VNCEvent: Sendable {
    case connected(width: Int, height: Int, name: String)
    case framebufferUpdated(x: Int, y: Int, width: Int, height: Int)
    case resized(width: Int, height: Int)
    case bell
    case serverCutText(String)
    case closed(reason: String?)
}

public enum VNCError: Error, Sendable, Equatable {
    case unsupportedVersion(String)
    case noAcceptableSecurity([UInt8])
    case authenticationFailed(String)
    case protocolError(String)
    case passwordRequired
    /// The server authenticates an account, so a user name is needed as well (D-031).
    case credentialsRequired
    /// The server's security is something this client will not do — VeNCrypt's own TLS,
    /// or a password in the clear on a connection with nothing over it. Distinct from a
    /// refused password: nothing the user types would change it.
    case unsupportedSecurity(String)
    /// A user name or password longer than the fixed field the format gives it.
    case credentialsTooLong
}

/// A VNC client over any NIO channel: a TCP connection, or an SSH `direct-tcpip` channel
/// (D-022). The handshake and every message are handled in `RFBClientHandler`; this
/// wraps it in an API the app can call.
public final class VNCClient: @unchecked Sendable {
    public let framebuffer: RFBFramebuffer
    public let events: AsyncStream<VNCEvent>
    private let continuation: AsyncStream<VNCEvent>.Continuation
    private let channel: Channel
    private let handler: RFBClientHandler

    public struct Options: Sendable {
        /// The account name, for a server that authenticates one — macOS Screen Sharing,
        /// or a VeNCrypt server (D-031). Blank for the classic single-password servers.
        public var username: String?
        public var password: String?
        public var shared: Bool = true
        /// Encodings to ask for, most preferred first; `nil` means the usual set.
        public var encodings: [RFB.Encoding]?
        /// Whether a password may be sent in the clear when the server offers nothing
        /// better. True only when something else is already encrypting the connection —
        /// an SSH channel or the Cloudflare carrier — and never on a direct one.
        public var allowsPlaintextAuthentication: Bool
        public init(
            username: String? = nil,
            password: String? = nil,
            shared: Bool = true,
            encodings: [RFB.Encoding]? = nil,
            allowsPlaintextAuthentication: Bool = false
        ) {
            self.username = username
            self.password = password
            self.shared = shared
            self.encodings = encodings
            self.allowsPlaintextAuthentication = allowsPlaintextAuthentication
        }
    }

    /// Runs the handshake on an already-connected channel and returns once the server
    /// has been initialised — or throws with the reason it refused.
    public static func start(on channel: Channel, options: Options) async throws -> VNCClient {
        let framebuffer = RFBFramebuffer(width: 1, height: 1)
        let (events, continuation) = AsyncStream<VNCEvent>.makeStream(bufferingPolicy: .unbounded)
        let ready = channel.eventLoop.makePromise(of: RFB.ServerInit.self)
        let handler = RFBClientHandler(options: options, framebuffer: framebuffer, events: continuation, ready: ready)
        try await channel.pipeline.addHandler(handler).get()
        let serverInit = try await ready.futureResult.get()
        continuation.yield(.connected(width: serverInit.width, height: serverInit.height, name: serverInit.name))
        return VNCClient(framebuffer: framebuffer, events: events, continuation: continuation, channel: channel, handler: handler)
    }

    /// Connects over plain TCP.
    public static func connect(host: String, port: Int, options: Options, group: EventLoopGroup) async throws -> VNCClient {
        let channel = try await ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .connect(host: host, port: port).get()
        return try await start(on: channel, options: options)
    }

    private init(framebuffer: RFBFramebuffer, events: AsyncStream<VNCEvent>, continuation: AsyncStream<VNCEvent>.Continuation, channel: Channel, handler: RFBClientHandler) {
        self.framebuffer = framebuffer
        self.events = events
        self.continuation = continuation
        self.channel = channel
        self.handler = handler
    }

    public func requestUpdate(incremental: Bool = true) {
        var buffer = channel.allocator.buffer(capacity: 10)
        RFB.framebufferUpdateRequest(incremental: incremental, x: 0, y: 0, width: framebuffer.width, height: framebuffer.height, into: &buffer)
        channel.writeAndFlush(buffer, promise: nil)
    }

    public func sendPointer(buttons: UInt8, x: Int, y: Int) {
        var buffer = channel.allocator.buffer(capacity: 6)
        RFB.pointerEvent(buttons: buttons, x: x, y: y, into: &buffer)
        channel.writeAndFlush(buffer, promise: nil)
    }

    public func sendKey(keysym: UInt32, down: Bool) {
        var buffer = channel.allocator.buffer(capacity: 8)
        RFB.keyEvent(keysym: keysym, down: down, into: &buffer)
        channel.writeAndFlush(buffer, promise: nil)
    }

    public func sendCutText(_ text: String) {
        var buffer = channel.allocator.buffer(capacity: 8 + text.utf8.count)
        RFB.clientCutText(text, into: &buffer)
        channel.writeAndFlush(buffer, promise: nil)
    }

    public func close() async {
        try? await channel.close().get()
    }
}

/// The protocol state machine. Runs on the channel's event loop; the framebuffer is
/// written here and read by the renderer after an event, which is the only crossing.
final class RFBClientHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private enum State {
        case version, securityTypes, securityResult, vncChallenge, serverInit, messages
        case appleChallenge, appleComputing
        case veNCryptVersion, veNCryptAck, veNCryptSubtypes
    }

    private let options: VNCClient.Options
    private let framebuffer: RFBFramebuffer
    private let events: AsyncStream<VNCEvent>.Continuation
    private let ready: EventLoopPromise<RFB.ServerInit>
    private var state: State = .version
    private var pending = ByteBuffer()
    private var rectanglesLeft = 0
    private var currentRect: RFB.Rectangle?
    private var updateBounds: (x: Int, y: Int, w: Int, h: Int)?
    private let zlib = ZlibInflater()
    private var readyFulfilled = false

    init(options: VNCClient.Options, framebuffer: RFBFramebuffer, events: AsyncStream<VNCEvent>.Continuation, ready: EventLoopPromise<RFB.ServerInit>) {
        self.options = options
        self.framebuffer = framebuffer
        self.events = events
        self.ready = ready
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        pending.writeBuffer(&incoming)
        do {
            try drain(context: context)
        } catch {
            fail(context: context, error)
        }
        pending.discardReadBytes()
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !readyFulfilled { readyFulfilled = true; ready.fail(VNCError.protocolError("closed during handshake")) }
        events.yield(.closed(reason: nil))
        events.finish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(context: context, error)
    }

    private func fail(context: ChannelHandlerContext, _ error: Error) {
        if !readyFulfilled { readyFulfilled = true; ready.fail(error) }
        events.yield(.closed(reason: String(describing: error)))
        events.finish()
        context.close(promise: nil)
    }

    private func send(_ context: ChannelHandlerContext, _ bytes: [UInt8]) {
        var buffer = context.channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        context.writeAndFlush(NIOAny(buffer), promise: nil)
    }

    /// Consumes as many complete messages as `pending` holds; returns when it needs more.
    private func drain(context: ChannelHandlerContext) throws {
        while true {
            switch state {
            case .version:
                guard let version = RFB.readVersion(from: &pending) else { return }
                guard version.major == 3, [3, 7, 8].contains(version.minor) || version.minor > 8 else {
                    throw VNCError.unsupportedVersion("\(version.major).\(version.minor)")
                }
                send(context, Array(RFB.clientVersion.utf8))
                state = version.minor == 3 ? .securityResult : .securityTypes
                if version.minor == 3 { state = .securityTypes } // 3.3 sends a u32 type; handled below
                serverMinor = version.minor

            case .securityTypes:
                if serverMinor == 3 {
                    guard let type: UInt32 = pending.readInteger() else { return }
                    if type == 0 { let reason = RFB.readReason(from: &pending) ?? "server refused"; throw VNCError.authenticationFailed(reason) }
                    try beginSecurity(UInt8(type), context)
                } else {
                    guard let count: UInt8 = pending.getInteger(at: pending.readerIndex) else { return }
                    if count == 0 {
                        pending.moveReaderIndex(forwardBy: 1)
                        let reason = RFB.readReason(from: &pending) ?? "server offered no security types"
                        throw VNCError.authenticationFailed(reason)
                    }
                    guard pending.readableBytes >= 1 + Int(count) else { return }
                    pending.moveReaderIndex(forwardBy: 1)
                    let offered = pending.readBytes(length: Int(count)) ?? []
                    let chosen = try RFB.chooseSecurity(
                        offered: offered,
                        hasUsername: !(options.username ?? "").isEmpty,
                        hasPassword: !(options.password ?? "").isEmpty
                    )
                    send(context, [chosen])
                    try beginSecurity(chosen, context)
                }

            case .appleChallenge:
                guard let challenge = try VNCAppleAuthentication.readChallenge(from: &pending) else { return }
                let username = options.username ?? ""
                let password = options.password ?? ""
                try VNCAppleAuthentication.validate(username: username, password: password)
                // The exponentiation is milliseconds of arithmetic, which is a long time to
                // hold an event loop that also serves other connections.
                state = .appleComputing
                let loop = context.eventLoop
                // The context may only be touched on its own loop; this is the type that
                // says so, rather than capturing it and hoping.
                let bound = NIOLoopBound(context, eventLoop: loop)
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    let result = Result {
                        try VNCAppleAuthentication.response(
                            to: challenge,
                            username: username,
                            password: password,
                            privateKey: Self.randomBytes(challenge.keyLength),
                            padding: Self.randomBytes(VNCAppleAuthentication.credentialsLength)
                        )
                    }
                    loop.execute { self.finishAppleAuthentication(result, bound.value) }
                }
                return

            case .appleComputing:
                // Whatever the server sends next stays in `pending` until the answer is out.
                return

            case .veNCryptVersion:
                guard pending.readableBytes >= 2, let version = pending.readBytes(length: 2) else { return }
                guard version[0] == 0, version[1] >= 2 else {
                    throw VNCError.protocolError("VeNCrypt \(version[0]).\(version[1]) is not supported")
                }
                send(context, [0, 2])
                state = .veNCryptAck

            case .veNCryptAck:
                guard let ack: UInt8 = pending.readInteger() else { return }
                guard ack == 0 else { throw VNCError.authenticationFailed("the server refused VeNCrypt 0.2") }
                state = .veNCryptSubtypes

            case .veNCryptSubtypes:
                guard let count: UInt8 = pending.getInteger(at: pending.readerIndex) else { return }
                guard count > 0 else { throw VNCError.authenticationFailed("the server offered no VeNCrypt sub-types") }
                guard pending.readableBytes >= 1 + Int(count) * 4 else { return }
                pending.moveReaderIndex(forwardBy: 1)
                var subtypes: [UInt32] = []
                for _ in 0 ..< count { subtypes.append(pending.readInteger() ?? 0) }
                let subtype = try chooseVeNCryptSubtype(subtypes)
                var reply = ByteBuffer()
                reply.writeInteger(subtype.rawValue)
                if subtype == .plain {
                    let username = Array((options.username ?? "").utf8)
                    let password = Array((options.password ?? "").utf8)
                    reply.writeInteger(UInt32(username.count))
                    reply.writeInteger(UInt32(password.count))
                    reply.writeBytes(username)
                    reply.writeBytes(password)
                }
                context.writeAndFlush(NIOAny(reply), promise: nil)
                state = subtype == .plain ? .securityResult : .vncChallenge

            case .vncChallenge:
                guard pending.readableBytes >= 16, let challenge = pending.readBytes(length: 16) else { return }
                guard let password = options.password else { throw VNCError.passwordRequired }
                send(context, VNCDES.encryptChallenge(challenge, password: password))
                state = .securityResult

            case .securityResult:
                guard let result: UInt32 = pending.readInteger() else { return }
                if result != 0 {
                    let reason = serverMinor >= 8 ? (RFB.readReason(from: &pending) ?? "authentication failed") : "authentication failed"
                    throw VNCError.authenticationFailed(reason)
                }
                send(context, [options.shared ? 1 : 0])
                state = .serverInit

            case .serverInit:
                guard let serverInit = RFB.readServerInit(from: &pending) else { return }
                framebuffer.withLock { framebuffer.resize(width: serverInit.width, height: serverInit.height) }
                var buffer = context.channel.allocator.buffer(capacity: 64)
                RFB.setPixelFormat(.client, into: &buffer)
                RFB.setEncodings(options.encodings ?? RFB.Encoding.preferred, into: &buffer)
                RFB.framebufferUpdateRequest(incremental: false, x: 0, y: 0, width: serverInit.width, height: serverInit.height, into: &buffer)
                context.writeAndFlush(NIOAny(buffer), promise: nil)
                state = .messages
                readyFulfilled = true
                ready.succeed(serverInit)

            case .messages:
                if rectanglesLeft > 0 {
                    guard try readRectangle(context: context) else { return }
                    continue
                }
                guard let type: UInt8 = pending.getInteger(at: pending.readerIndex) else { return }
                switch RFB.ServerMessage(rawValue: type) {
                case .framebufferUpdate:
                    guard pending.readableBytes >= 4 else { return }
                    pending.moveReaderIndex(forwardBy: 2)
                    let count: UInt16 = pending.readInteger()!
                    rectanglesLeft = Int(count)
                    updateBounds = nil
                    if rectanglesLeft == 0 { finishUpdate(context: context) }
                case .setColourMapEntries:
                    guard pending.readableBytes >= 6, let count: UInt16 = pending.getInteger(at: pending.readerIndex + 4),
                          pending.readableBytes >= 6 + Int(count) * 6 else { return }
                    pending.moveReaderIndex(forwardBy: 6 + Int(count) * 6)
                case .bell:
                    pending.moveReaderIndex(forwardBy: 1)
                    events.yield(.bell)
                case .serverCutText:
                    guard pending.readableBytes >= 8, let length: UInt32 = pending.getInteger(at: pending.readerIndex + 4),
                          pending.readableBytes >= 8 + Int(length) else { return }
                    pending.moveReaderIndex(forwardBy: 8)
                    let bytes = pending.readBytes(length: Int(length)) ?? []
                    events.yield(.serverCutText(String(bytes.map { Character(UnicodeScalar($0)) })))
                case .none:
                    throw VNCError.protocolError("unknown server message \(type)")
                }
            }
        }
    }

    private var serverMinor = 8

    private func beginSecurity(_ type: UInt8, _ context: ChannelHandlerContext) throws {
        switch RFB.SecurityType(rawValue: type) {
        case .noAuthentication?:
            // 3.8 sends a SecurityResult even for None; 3.3 and 3.7 do not.
            if serverMinor >= 8 { state = .securityResult } else { send(context, [options.shared ? 1 : 0]); state = .serverInit }
        case .vncAuthentication?:
            state = .vncChallenge
        case .appleRemoteDesktop?:
            state = .appleChallenge
        case .veNCrypt?:
            state = .veNCryptVersion
        default:
            throw VNCError.noAcceptableSecurity([type])
        }
    }

    /// The best VeNCrypt sub-type this client can actually complete.
    private func chooseVeNCryptSubtype(_ offered: [UInt32]) throws -> RFB.VeNCryptSubtype {
        let known = offered.compactMap(RFB.VeNCryptSubtype.init(rawValue:))
        if known.contains(.vncAuthentication), !(options.password ?? "").isEmpty { return .vncAuthentication }
        if known.contains(.plain), !(options.password ?? "").isEmpty {
            // Plain is the user name and the password as they are, with nothing over them.
            // Inside an SSH channel or the Cloudflare carrier that is someone else's
            // encryption and fine; on a direct connection it is the password in the clear,
            // which is worth refusing rather than doing quietly.
            guard options.allowsPlaintextAuthentication else {
                throw VNCError.unsupportedSecurity("VeNCrypt Plain on an unencrypted connection")
            }
            return .plain
        }
        if known.allSatisfy(\.needsTLS), !known.isEmpty {
            throw VNCError.unsupportedSecurity("VeNCrypt TLS")
        }
        if !(options.password ?? "").isEmpty { throw VNCError.noAcceptableSecurity([]) }
        throw VNCError.passwordRequired
    }

    /// Sends the answer worked out off the event loop, then picks the handshake back up.
    private func finishAppleAuthentication(_ result: Result<[UInt8], Error>, _ context: ChannelHandlerContext) {
        switch result {
        case let .success(response):
            send(context, response)
            state = .securityResult
            do { try drain(context: context) } catch { fail(context: context, error) }
        case let .failure(error):
            fail(context: context, error)
        }
    }

    private static func randomBytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0 ..< count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }

    /// Reads one rectangle if it is complete. Returns false to wait for more bytes.
    private func readRectangle(context: ChannelHandlerContext) throws -> Bool {
        if currentRect == nil {
            guard pending.readableBytes >= 12, let x: UInt16 = pending.getInteger(at: pending.readerIndex),
                  let y: UInt16 = pending.getInteger(at: pending.readerIndex + 2),
                  let w: UInt16 = pending.getInteger(at: pending.readerIndex + 4),
                  let h: UInt16 = pending.getInteger(at: pending.readerIndex + 6),
                  let encoding: Int32 = pending.getInteger(at: pending.readerIndex + 8) else { return false }
            pending.moveReaderIndex(forwardBy: 12)
            currentRect = RFB.Rectangle(x: Int(x), y: Int(y), width: Int(w), height: Int(h), encoding: encoding)
        }
        guard let rect = currentRect else { return false }
        let start = pending.readerIndex
        let decoded = try framebuffer.withLock {
            try RFBDecoder.decode(rect: rect, from: &pending, into: framebuffer, zlib: zlib)
        }
        guard decoded else { pending.moveReaderIndex(to: start); return false }
        if rect.encoding == RFB.Encoding.desktopSize.rawValue {
            events.yield(.resized(width: rect.width, height: rect.height))
        } else if rect.encoding != RFB.Encoding.cursor.rawValue {
            updateBounds = union(updateBounds, (rect.x, rect.y, rect.width, rect.height))
        }
        currentRect = nil
        rectanglesLeft -= 1
        if rectanglesLeft == 0 { finishUpdate(context: context) }
        return true
    }

    private func finishUpdate(context: ChannelHandlerContext) {
        if let bounds = updateBounds {
            events.yield(.framebufferUpdated(x: bounds.x, y: bounds.y, width: bounds.w, height: bounds.h))
        }
        // Ask for the next incremental update at once; the server answers when something changes.
        var buffer = context.channel.allocator.buffer(capacity: 10)
        RFB.framebufferUpdateRequest(incremental: true, x: 0, y: 0, width: framebuffer.width, height: framebuffer.height, into: &buffer)
        context.writeAndFlush(NIOAny(buffer), promise: nil)
    }

    private func union(_ a: (x: Int, y: Int, w: Int, h: Int)?, _ b: (x: Int, y: Int, w: Int, h: Int)) -> (x: Int, y: Int, w: Int, h: Int) {
        guard let a else { return b }
        let x0 = min(a.x, b.x), y0 = min(a.y, b.y)
        let x1 = max(a.x + a.w, b.x + b.w), y1 = max(a.y + a.h, b.y + b.h)
        return (x0, y0, x1 - x0, y1 - y0)
    }
}
