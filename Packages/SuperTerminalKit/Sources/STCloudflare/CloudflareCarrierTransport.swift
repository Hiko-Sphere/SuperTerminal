import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOTransportServices
import NIOWebSocket
import Network
import STCore

/// Establishes the Cloudflare Access carrier: a TLS WebSocket to the Access-protected
/// hostname whose binary frames carry the raw TCP byte stream of the origin SSH
/// service.
///
/// This is the component that replaces `ProxyCommand cloudflared access ssh` on the
/// desktop. Rather than shelling out to a helper binary — which iOS does not permit —
/// it speaks the same wire protocol directly: an HTTP/1.1 WebSocket upgrade carrying
/// the Access credential in the `Cf-Access-Token` (or service-token) headers, after
/// which every binary frame in each direction is opaque TCP payload.
public struct CloudflareCarrierTransport: ByteStreamTransport {
    /// How the carrier's transport is secured.
    ///
    /// There is exactly one production value. The loopback case exists so the carrier
    /// protocol can be exercised against a local server, and it refuses at runtime to
    /// contact anything that is not loopback — so it cannot be used, by mistake or on
    /// purpose, to weaken a connection to a real host.
    public enum Security: Sendable {
        /// System TLS via Network.framework, with the platform's full certificate
        /// validation. This is what every connection the app makes uses.
        case systemTLS
        /// Plaintext, permitted only when the destination is 127.0.0.1 or ::1.
        case plaintextLoopbackOnly
    }

    /// Header Cloudflare's edge reads the Access application token from.
    public static let accessTokenHeader = "Cf-Access-Token"
    /// Headers used by non-interactive Access service tokens.
    public static let serviceTokenIDHeader = "Cf-Access-Client-Id"
    public static let serviceTokenSecretHeader = "Cf-Access-Client-Secret"
    /// Header naming the final destination when the tunnel runs in bastion mode.
    public static let jumpDestinationHeader = "Cf-Access-Jump-Destination"

    public struct Configuration: Sendable {
        /// The Access-protected hostname, e.g. `ssh.example.com`.
        public var host: String
        /// The port the Cloudflare edge is reached on. Effectively always 443.
        public var port: Int
        /// When the tunnel is configured as a bastion, the `host:port` behind it.
        public var jumpDestination: String?
        /// Largest single inbound WebSocket frame that will be accepted.
        public var maxFrameSize: Int
        public var userAgent: String
        public var connectTimeout: TimeAmount
        /// Interval between WebSocket ping frames. Pings keep the edge's idle timer
        /// from expiring on a quiet session and detect a peer that has gone away.
        public var pingInterval: TimeAmount
        public var security: Security

        public init(
            host: String,
            port: Int = 443,
            jumpDestination: String? = nil,
            maxFrameSize: Int = 1 << 20,
            userAgent: String,
            connectTimeout: TimeAmount = .seconds(20),
            pingInterval: TimeAmount = .seconds(30),
            security: Security = .systemTLS
        ) {
            self.host = host
            self.port = port
            self.jumpDestination = jumpDestination
            self.maxFrameSize = maxFrameSize
            self.userAgent = userAgent
            self.connectTimeout = connectTimeout
            self.pingInterval = pingInterval
            self.security = security
        }
    }

    private let configuration: Configuration
    private let credential: AccessCredential
    private let log: STLogger

    public init(configuration: Configuration, credential: AccessCredential, log: STLogger = .disabled) {
        self.configuration = configuration
        self.credential = credential
        self.log = log.child(subsystem: "cloudflare.carrier")
    }

    public var transportDescription: String {
        "cloudflare-access-ws://\(Redactor.hostname(configuration.host)):\(configuration.port)"
    }

    public func connect(on eventLoop: EventLoop) async throws -> Channel {
        let headers = buildHeaders()
        let upgradePromise = eventLoop.makePromise(of: Void.self)
        let outcome = CarrierUpgradeOutcome(promise: upgradePromise)
        let log = self.log
        let configuration = self.configuration

        let upgrader = NIOWebSocketClientUpgrader(
            maxFrameSize: configuration.maxFrameSize,
            // The byte-stream handler answers protocol errors itself with a precise
            // close code; the generic handler would race it.
            automaticErrorHandling: false
        ) { channel, _ in
            // The outcome handler exists only to classify a *failed* upgrade. It sits
            // where HTTP response parts arrive, which after the upgrade is where framed
            // WebSocket data arrives — so it must come out of the pipeline before the
            // byte-stream handler goes in, not merely be bypassed.
            channel.pipeline.handler(type: CarrierUpgradeOutcomeHandler.self)
                .flatMap { channel.pipeline.removeHandler($0) }
                .flatMapError { _ in channel.eventLoop.makeSucceededVoidFuture() }
                .flatMap {
                    channel.pipeline.addHandler(
                        WebSocketByteStreamHandler(log: log, pingInterval: configuration.pingInterval)
                    )
                }
                .always { result in
                    switch result {
                    case .success: outcome.succeed()
                    case let .failure(error): outcome.fail(error)
                    }
                }
        }

        if case .plaintextLoopbackOnly = configuration.security, !Self.isLoopback(configuration.host) {
            let error = STError(
                category: .configuration,
                message: "Refusing to open an unencrypted Cloudflare carrier to a non-loopback host.",
                underlyingDescription: "plaintextLoopbackOnly is only valid for 127.0.0.1, ::1 or localhost"
            )
            // The promise must be resolved on every path out of this function; NIO
            // traps on a promise that is dropped unfulfilled.
            outcome.fail(error)
            throw error
        }

        var bootstrap = NIOTSConnectionBootstrap(group: eventLoop)
            .connectTimeout(configuration.connectTimeout)
        if case .systemTLS = configuration.security {
            // System TLS via Network.framework: certificate validation, revocation
            // policy and TLS version floor all follow the platform's rules. There is
            // no hook here to weaken them.
            bootstrap = bootstrap.tlsOptions(NWProtocolTLS.Options())
        }
        bootstrap = bootstrap
            .channelInitializer { channel in
                // Both handlers are created inside the initialiser, so they are never
                // shared across loops.
                let requestWriter = CarrierUpgradeRequestHandler(
                    host: configuration.host,
                    port: configuration.port,
                    headers: headers
                )
                let outcomeHandler = CarrierUpgradeOutcomeHandler(outcome: outcome, log: log)
                return channel.pipeline.addHTTPClientHandlers(
                    leftOverBytesStrategy: .forwardBytes,
                    withClientUpgrade: (upgraders: [upgrader], completionHandler: { _ in })
                ).flatMapThrowing {
                    try channel.pipeline.syncOperations.addHandlers([requestWriter, outcomeHandler])
                }
            }

        let channel: Channel
        do {
            channel = try await bootstrap.connect(host: configuration.host, port: configuration.port).get()
        } catch {
            outcome.fail(error)
            throw STError(
                category: .network,
                message: "Could not reach \(configuration.host).",
                recoverySuggestion: "Check your network connection and that the hostname is correct.",
                underlyingDescription: String(describing: error)
            )
        }

        do {
            try await upgradePromise.futureResult.get()
        } catch {
            try? await channel.close().get()
            throw error
        }

        log.info("Cloudflare carrier established", [
            "host": Redactor.hostname(configuration.host),
            "credential": credentialKind,
        ])
        return channel
    }

    static func isLoopback(_ host: String) -> Bool {
        let normalised = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return normalised == "127.0.0.1" || normalised == "::1" || normalised == "localhost"
    }

    private var credentialKind: String {
        switch credential {
        case .userToken: "user-token"
        case .serviceToken: "service-token"
        case .none: "none"
        }
    }

    func buildHeaders() -> [(String, String)] {
        var headers: [(String, String)] = [("User-Agent", configuration.userAgent)]
        switch credential {
        case let .userToken(token):
            headers.append((Self.accessTokenHeader, token.token.reveal()))
        case let .serviceToken(service):
            headers.append((Self.serviceTokenIDHeader, service.clientID))
            headers.append((Self.serviceTokenSecretHeader, service.clientSecret.reveal()))
        case .none:
            break
        }
        if let jump = configuration.jumpDestination, !jump.isEmpty {
            headers.append((Self.jumpDestinationHeader, jump))
        }
        return headers
    }
}

/// Sends the WebSocket upgrade request as soon as the TLS connection is up.
///
/// The upgrade handler below it fills in `Upgrade`, `Connection`, `Sec-WebSocket-Key`
/// and `Sec-WebSocket-Version`; everything Access-specific is added here.
final class CarrierUpgradeRequestHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = Never
    typealias OutboundOut = HTTPClientRequestPart

    private let host: String
    private let port: Int
    private let headers: [(String, String)]

    init(host: String, port: Int, headers: [(String, String)]) {
        self.host = host
        self.port = port
        self.headers = headers
    }

    func channelActive(context: ChannelHandlerContext) {
        var requestHeaders = HTTPHeaders()
        requestHeaders.add(name: "Host", value: port == 443 ? host : "\(host):\(port)")
        requestHeaders.add(name: "Content-Length", value: "0")
        for (name, value) in headers {
            requestHeaders.add(name: name, value: value)
        }

        let head = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: "/",
            headers: requestHeaders
        )
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        context.fireChannelActive()
        context.pipeline.syncOperations.removeHandler(context: context, promise: nil)
    }
}

/// Classifies the outcome of the upgrade attempt.
///
/// A non-101 response is where every interesting Cloudflare failure shows up, and each
/// one needs a different recovery. Turning them into distinct errors here is what lets
/// the UI say "sign in again" rather than "connection failed".
/// Guards the single completion of the upgrade promise.
///
/// Success is reported by the upgrade pipeline callback, failure by the handler below,
/// and either can happen first. An `EventLoopPromise` traps on double completion, so the
/// race is resolved here rather than left to ordering luck.
final class CarrierUpgradeOutcome: @unchecked Sendable {
    private let promise: EventLoopPromise<Void>
    private let completed = NIOLockedValueBox(false)

    init(promise: EventLoopPromise<Void>) {
        self.promise = promise
    }

    private func claim() -> Bool {
        completed.withLockedValue { alreadyDone in
            if alreadyDone { return false }
            alreadyDone = true
            return true
        }
    }

    func succeed() {
        if claim() { promise.succeed(()) }
    }

    func fail(_ error: any Error) {
        if claim() { promise.fail(error) }
    }
}

/// Classifies a *failed* upgrade attempt.
///
/// Every interesting Cloudflare failure shows up as a non-101 response, and each one
/// needs a different recovery. Turning them into distinct errors here is what lets the
/// UI say "sign in again" rather than "connection failed".
final class CarrierUpgradeOutcomeHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart

    private let outcome: CarrierUpgradeOutcome
    private let log: STLogger

    init(outcome: CarrierUpgradeOutcome, log: STLogger) {
        self.outcome = outcome
        self.log = log
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if case let .head(head) = unwrapInboundIn(data) {
            log.debug("carrier upgrade refused", ["status": "\(head.status.code)"])
            outcome.fail(Self.classify(head))
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        outcome.fail(error)
        context.fireErrorCaught(error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        outcome.fail(STError(
            category: .network,
            message: "The connection to Cloudflare closed before the tunnel was established.",
            recoverySuggestion: "Try again. If it persists, check that the tunnel is running."
        ))
        context.fireChannelInactive()
    }

    static func classify(_ head: HTTPResponseHead) -> STError {
        let location = head.headers.first(name: "Location")?.lowercased() ?? ""
        let isRedirect = (300 ..< 400).contains(Int(head.status.code))
        if isRedirect, location.contains("/cdn-cgi/access/login") {
            return AccessError.accessDenied("edge redirected to the Access login page").stError
        }
        switch head.status.code {
        case 101:
            return STError(category: .internalError, message: "Upgrade succeeded but was reported as a response.")
        case 401, 403:
            return STError(
                category: .access,
                message: "Cloudflare Access refused this connection.",
                recoverySuggestion: "Sign in again, or ask your administrator whether your identity is allowed by this application's policy.",
                underlyingDescription: "HTTP \(head.status.code)"
            )
        case 404:
            return STError(
                category: .tunnel,
                message: "Cloudflare has no route for this hostname.",
                recoverySuggestion: "Check the hostname, and that a Cloudflare Tunnel public hostname points at your SSH service.",
                underlyingDescription: "HTTP 404"
            )
        case 502, 503, 504:
            return STError(
                category: .tunnel,
                message: "The Cloudflare Tunnel could not reach the SSH service.",
                recoverySuggestion: "Check that cloudflared is running on the origin and that its ingress rule points at the SSH port.",
                underlyingDescription: "HTTP \(head.status.code)"
            )
        case 530:
            return STError(
                category: .tunnel,
                message: "Cloudflare could not connect to the origin (error 1033).",
                recoverySuggestion: "The tunnel is offline. Start cloudflared on the origin host and try again.",
                underlyingDescription: "HTTP 530"
            )
        default:
            return STError(
                category: .network,
                message: "Cloudflare rejected the tunnel request (HTTP \(head.status.code)).",
                recoverySuggestion: "Check the hostname and tunnel configuration.",
                underlyingDescription: "HTTP \(head.status.code) \(head.status.reasonPhrase)"
            )
        }
    }
}
