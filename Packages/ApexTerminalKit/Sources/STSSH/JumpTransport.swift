import NIOCore
import STCore

/// An SSH connection carried inside another one — `ssh -J`, a jump host (D-047).
///
/// The channel a jump opens is an ordinary `direct-tcpip` channel on the connection it
/// jumps through: the first server makes the TCP connection on the device's behalf and
/// hands back a byte stream, which is exactly what the SSH transport needs. So a jump is
/// not a special kind of connection, it is the same connection over a different pipe —
/// which is why every check still applies to the far end. The second server's host key is
/// verified against the second server's own record, and its credentials are its own.
///
/// That matters more than it sounds. A jump host is a machine that can see the traffic's
/// destination but never its contents: the inner SSH session is encrypted end to end
/// between this device and the final server, and a compromised bastion can drop the
/// connection but cannot read it or impersonate the far end without a host key it does not
/// have.
public struct JumpTransport: ByteStreamTransport {
    private let carrier: SSHConnection
    private let endpoint: TransportEndpoint
    private let carrierDescription: String

    public init(through carrier: SSHConnection, to endpoint: TransportEndpoint, carrierDescription: String) {
        self.carrier = carrier
        self.endpoint = endpoint
        self.carrierDescription = carrierDescription
    }

    public var transportDescription: String {
        "jump://\(carrierDescription)/\(Redactor.hostname(endpoint.host)):\(endpoint.port)"
    }

    public func connect(on eventLoop: EventLoop) async throws -> Channel {
        // The event loop is the carrier's, not the one passed in: the channel belongs to
        // the connection it is opened on and cannot be moved.
        try await carrier.openDirectTCPIP(host: endpoint.host, port: endpoint.port)
    }
}
