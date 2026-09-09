import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// An SSH server that does what a well-behaved one never would: opens channels back to the
/// client that the client never asked for (D-060).
///
/// The User Notice tells people that a server cannot reach into this device — that a
/// forwarded connection arrives only where a forward was asked for, and that the agent
/// answers only where agent forwarding was turned on. Those are claims about what the
/// *client* refuses, and the only way to test a refusal is to have something try.
///
/// Deliberately minimal: it accepts any password, keeps the connection open, and opens
/// whatever channel a test asks it to.
public final class HostileSSHTestServer: @unchecked Sendable {
    public enum StartupError: Error, CustomStringConvertible {
        case neverConnected

        public var description: String {
            switch self {
            case .neverConnected: "no client connected to the hostile server"
            }
        }
    }

    public let port: Int
    public let username = "victim"
    public let password = "correct horse battery staple"

    private let group: MultiThreadedEventLoopGroup
    private let listener: Channel
    private let state = State()
    private var stopped = false

    /// What the server itself saw go wrong, for when a test fails for a reason that is
    /// not the one it is about.
    public var serverErrors: [String] { state.errors }

    /// Holds the connected client's handler so a test can drive it.
    fileprivate final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var handler: NIOSSHHandler?
        private var channel: Channel?
        private var recorded: [String] = []

        func record(_ error: any Error) { lock.withLock { recorded.append(String(describing: error)) } }
        var errors: [String] { lock.withLock { recorded } }

        func store(handler: NIOSSHHandler, channel: Channel) {
            lock.withLock {
                self.handler = handler
                self.channel = channel
            }
        }

        var connected: (NIOSSHHandler, Channel)? {
            lock.withLock {
                guard let handler, let channel else { return nil }
                return (handler, channel)
            }
        }
    }

    /// - Parameter transportProtectionSchemes: the ciphers this server offers. Pass the
    ///   client's own list: with only the library's bundled schemes, the server advertises
    ///   no MAC the client accepts — the app offers encrypt-then-MAC only, which every real
    ///   OpenSSH does too — and the handshake fails before any channel can be opened.
    public init(transportProtectionSchemes: [NIOSSHTransportProtection.Type] = []) throws {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let hostKey = NIOSSHPrivateKey(ed25519Key: .init())
        let state = state
        listener = try ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let handler = NIOSSHHandler(
                        role: .server(.init(
                            hostKeys: [hostKey],
                            userAuthDelegate: AcceptAnyPassword(),
                            globalRequestDelegate: AcceptAnyForward(),
                            banner: nil,
                            transportProtectionSchemes: transportProtectionSchemes.isEmpty
                                ? Constants.bundledTransportProtectionSchemes
                                : transportProtectionSchemes
                        )),
                        allocator: channel.allocator,
                        // A session channel is accepted so the client can get as far as
                        // running something; nothing else is offered.
                        inboundChildChannelInitializer: { child, type in
                            guard case .session = type else {
                                return child.eventLoop.makeFailedFuture(ChannelError.operationUnsupported)
                            }
                            return child.eventLoop.makeSucceededVoidFuture()
                        }
                    )
                    try channel.pipeline.syncOperations.addHandler(handler)
                    try channel.pipeline.syncOperations.addHandler(ErrorRecorder(state: state))
                    state.store(handler: handler, channel: channel)
                }
            }
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .bind(host: "127.0.0.1", port: 0)
            .wait()
        port = listener.localAddress?.port ?? 0
    }

    deinit { shutDown() }

    public func shutDown() {
        guard !stopped else { return }
        stopped = true
        try? listener.close().wait()
        try? group.syncShutdownGracefully()
    }

    /// Tries to open a channel the client never asked for, and reports whether the client
    /// took it.
    ///
    /// Returns `true` if the client accepted — which for every type here would be a defect.
    public func openUnrequestedChannel(_ type: SSHChannelType, timeout: TimeInterval = 10) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var connection: (NIOSSHHandler, Channel)?
        while Date() < deadline, connection == nil {
            connection = state.connected
            if connection == nil { Thread.sleep(forTimeInterval: 0.05) }
        }
        guard let (handler, channel) = connection else { throw StartupError.neverConnected }

        let promise = channel.eventLoop.makePromise(of: Channel.self)
        channel.eventLoop.execute {
            handler.createChannel(promise, channelType: type) { child, _ in
                child.eventLoop.makeSucceededVoidFuture()
            }
        }
        do {
            let opened = try promise.futureResult.wait()
            try? opened.close().wait()
            return true
        } catch {
            return false
        }
    }

    /// Whether the connection is still usable after a refusal — a client that dropped the
    /// whole session because it refused one channel would be denial-of-service by design.
    public var isConnectionAlive: Bool { state.connected?.1.isActive ?? false }
}

/// Says yes to `tcpip-forward` without listening on anything.
///
/// A test needs the client to have *a* registered forward so that a channel for a
/// different port can be shown to be refused. What the server does with the request is
/// irrelevant here: nothing on the far side ever connects.
private final class AcceptAnyForward: GlobalRequestDelegate {
    func tcpForwardingRequest(
        _ request: GlobalRequest.TCPForwardingRequest,
        handler: NIOSSHHandler,
        promise: EventLoopPromise<GlobalRequest.TCPForwardingResponse>
    ) {
        switch request {
        case let .listen(_, port):
            promise.succeed(GlobalRequest.TCPForwardingResponse(boundPort: port))
        case .cancel:
            promise.succeed(GlobalRequest.TCPForwardingResponse(boundPort: nil))
        }
    }
}

private final class ErrorRecorder: ChannelInboundHandler {
    typealias InboundIn = Any

    let state: HostileSSHTestServer.State
    init(state: HostileSSHTestServer.State) { self.state = state }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        state.record(error)
        context.fireErrorCaught(error)
    }
}

/// Accepts any password. This server exists to be hostile *after* authentication; making
/// it hard to log in to would only make the tests longer.
private final class AcceptAnyPassword: NIOSSHServerUserAuthenticationDelegate {
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .password

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        guard case .password = request.request else {
            responsePromise.succeed(.failure)
            return
        }
        responsePromise.succeed(.success)
    }
}
