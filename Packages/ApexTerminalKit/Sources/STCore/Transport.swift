import Foundation
import NIOCore

/// Describes where a byte-stream transport should terminate.
public struct TransportEndpoint: Sendable, Hashable {
    public let host: String
    public let port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
}

/// A factory that produces a NIO `Channel` carrying a raw, ordered, reliable byte
/// stream to the SSH server.
///
/// Both transports ApexTerminal ships — a direct TCP connection and a Cloudflare
/// Access WebSocket carrier — vend a channel with the same contract, so the SSH
/// layer is written once and is unaware of which path it is running over:
///
/// * inbound: `ByteBuffer` containing server-to-client bytes, in order
/// * outbound: `ByteBuffer` containing client-to-server bytes, in order
///
/// The returned channel has **no** handlers installed above the byte-stream layer;
/// the caller owns the rest of the pipeline.
public protocol ByteStreamTransport: Sendable {
    /// Human-readable identifier used in diagnostics. Must not contain secrets.
    var transportDescription: String { get }

    /// Establishes the transport and returns a channel whose pipeline tail speaks
    /// `ByteBuffer` in both directions.
    func connect(on eventLoop: EventLoop) async throws -> Channel
}

/// Classification for every error surfaced to the user, so the UI can offer a
/// specific, actionable recovery rather than a generic failure alert.
public enum STErrorCategory: String, Sendable, Codable, CaseIterable {
    /// The network is unreachable, DNS failed, or the connection dropped.
    case network
    /// TLS validation failed against the Cloudflare edge.
    case tls
    /// Cloudflare Access refused, or the token is missing, expired or wrong-audience.
    case access
    /// The Cloudflare Tunnel could not reach the origin service.
    case tunnel
    /// SSH transport-layer failure: version exchange, key exchange, MAC.
    case sshTransport
    /// SSH host key is unknown, changed, or rejected by the user.
    case hostKey
    /// SSH user authentication failed.
    case sshAuthentication
    /// SSH channel-layer failure: PTY request, shell request, exec.
    case sshChannel
    /// A local key, keychain item, or stored credential could not be used.
    case credential
    /// The user cancelled, or the operation was deliberately aborted.
    case cancelled
    /// A defect in configuration supplied by the user.
    case configuration
    /// Anything that does not fit above; always accompanied by a specific message.
    case internalError
}

/// The single error type crossing module boundaries. Every case carries a category
/// (drives UI recovery affordances), a message safe to display, and an optional
/// recovery suggestion.
public struct STError: Error, Sendable, Equatable {
    public let category: STErrorCategory
    public let message: String
    public let recoverySuggestion: String?
    public let underlyingDescription: String?

    public init(
        category: STErrorCategory,
        message: String,
        recoverySuggestion: String? = nil,
        underlyingDescription: String? = nil
    ) {
        self.category = category
        self.message = message
        self.recoverySuggestion = recoverySuggestion
        self.underlyingDescription = underlyingDescription
    }
}

extension STError: LocalizedError {
    public var errorDescription: String? { message }
}
