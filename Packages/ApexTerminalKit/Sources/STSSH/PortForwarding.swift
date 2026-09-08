import NIOConcurrencyHelpers
import NIOCore
import NIOSSH
import STCore

/// Where a connection the server pushes at us is supposed to go.
///
/// Remote forwarding (`ssh -R`) inverts the usual direction: the server listens, and when
/// something connects to it the *server* opens a channel to this client. Those channels
/// arrive unannounced, so something has to decide whether each one was asked for.
///
/// This is that decision, and it is deliberately a refusal by default. A `forwarded-tcpip`
/// channel whose listening address matches no rule is rejected rather than accepted and
/// quietly dropped: accepting it would let a server — or anything that has taken one over —
/// push connections into the app that nobody asked for.
public final class ForwardedChannelRouter: @unchecked Sendable {
    /// Handed an accepted channel and the address it arrived on. Called on the channel's
    /// own event loop.
    public typealias Route = @Sendable (Channel, SSHChannelType.ForwardedTCPIP) -> Void

    private let lock = NIOLock()
    private var routes: [Key: Route] = [:]

    private struct Key: Hashable {
        var host: String?
        var port: Int
    }

    public init() {}

    func register(host: String, port: Int, route: @escaping Route) {
        lock.withLock { routes[Key(host: host, port: port)] = route }
    }

    func deregister(host: String, port: Int) {
        lock.withLock { _ = routes.removeValue(forKey: Key(host: host, port: port)) }
    }

    /// The route for an arriving channel, or `nil` if nobody asked for it.
    ///
    /// Matched on the exact address first, then on the port alone. The second step is
    /// needed because the address a server reports is not always the one that was asked
    /// for: a request to bind `""` or `localhost` comes back as whatever the server chose
    /// to call it. Falling back to the port is what makes the common case work, and it is
    /// only ever a fallback — an exact match always wins.
    func route(host: String, port: Int) -> Route? {
        lock.withLock { () -> Route? in
            if let exact = routes[Key(host: host, port: port)] { return exact }
            let onPort = routes.filter { $0.key.port == port }
            return onPort.count == 1 ? onPort.first?.value : nil
        }
    }

    var isEmpty: Bool { lock.withLock { routes.isEmpty } }
}

public extension SSHConnection {
    /// Asks the server to listen on `port` and send us what connects to it.
    ///
    /// Returns the port the server actually bound, which is the requested one unless 0 was
    /// asked for — the protocol's way of saying "any free port", and the only way to learn
    /// which one that was.
    ///
    /// - Parameter onConnection: called for each accepted connection, on the channel's own
    ///   event loop. The channel already speaks `ByteBuffer`.
    @discardableResult
    func startRemoteForward(
        bindHost: String,
        port: Int,
        onConnection: @escaping ForwardedChannelRouter.Route
    ) async throws -> Int {
        let promise = eventLoop.makePromise(of: GlobalRequest.TCPForwardingResponse?.self)
        let handler = sshHandler
        eventLoop.execute {
            handler.withIsolatedValue { sshHandler in
                sshHandler.sendTCPForwardingRequest(.listen(host: bindHost, port: port), promise: promise)
            }
        }
        let response: GlobalRequest.TCPForwardingResponse?
        do {
            response = try await promise.futureResult.get()
        } catch {
            throw STError(
                category: .sshChannel,
                // As text, so the port is not formatted as a quantity: "port 8,080" is
                // not a port.
                message: String(
                    localized: "The server refused to listen on port \(String(port)).",
                    bundle: .module
                ),
                recoverySuggestion: String(
                    localized: "The port may already be in use, or the server may not allow remote forwarding — check that its sshd has AllowTcpForwarding and, for a port below 1024 or a non-local address, GatewayPorts.",
                    bundle: .module
                ),
                underlyingDescription: String(describing: error)
            )
        }
        let bound = response?.boundPort ?? port
        forwardedChannels.register(host: bindHost, port: bound, route: onConnection)
        log.info("remote forward established", ["host": bindHost, "port": "\(bound)"])
        return bound
    }

    /// Stops a remote forward. The route is dropped first, so a connection that races the
    /// cancellation is refused rather than delivered to something already torn down.
    func cancelRemoteForward(bindHost: String, port: Int) async throws {
        forwardedChannels.deregister(host: bindHost, port: port)
        let promise = eventLoop.makePromise(of: GlobalRequest.TCPForwardingResponse?.self)
        let handler = sshHandler
        eventLoop.execute {
            handler.withIsolatedValue { sshHandler in
                sshHandler.sendTCPForwardingRequest(.cancel(host: bindHost, port: port), promise: promise)
            }
        }
        // A server that has already forgotten the forward answers with a failure, which is
        // not worth reporting: the forward is gone either way, which is what was asked for.
        _ = try? await promise.futureResult.get()
        log.info("remote forward cancelled", ["host": bindHost, "port": "\(port)"])
    }
}
