import Foundation
import NIOCore
import NIOTransportServices
import Network
import STCore

/// A plain TCP connection to an SSH server.
///
/// Uses Network.framework through NIOTransportServices rather than BSD sockets: on
/// iOS that is what gives correct behaviour when the device changes network, when the
/// app is backgrounded, and when the destination is only reachable over IPv6 or over a
/// NAT64 network — all situations a mobile SSH client hits constantly and a raw socket
/// handles badly.
public struct DirectTCPTransport: ByteStreamTransport {
    private let endpoint: TransportEndpoint
    private let connectTimeout: TimeAmount
    private let log: STLogger

    public init(endpoint: TransportEndpoint, connectTimeout: TimeAmount = .seconds(20), log: STLogger = .disabled) {
        self.endpoint = endpoint
        self.connectTimeout = connectTimeout
        self.log = log.child(subsystem: "ssh.tcp")
    }

    public var transportDescription: String {
        "tcp://\(Redactor.hostname(endpoint.host)):\(endpoint.port)"
    }

    public func connect(on eventLoop: EventLoop) async throws -> Channel {
        let tcp = NWProtocolTCP.Options()
        // Interactive typing: send immediately rather than batching for throughput.
        tcp.noDelay = true
        // TCP keepalive is the liveness probe for a direct connection: it detects a
        // peer that has gone away without a FIN, which is exactly what happens when a
        // phone moves between networks or a NAT drops the mapping.
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        tcp.keepaliveInterval = 10
        tcp.keepaliveCount = 3

        do {
            return try await NIOTSConnectionBootstrap(group: eventLoop)
                .connectTimeout(connectTimeout)
                .channelOption(NIOTSChannelOptions.waitForActivity, value: false)
                .tcpOptions(tcp)
                .connect(host: endpoint.host, port: endpoint.port)
                .get()
        } catch {
            throw STError(
                category: .network,
                message: "Could not connect to \(endpoint.host) on port \(endpoint.port).",
                recoverySuggestion: "Check the hostname, the port, and that the server is reachable from this network.",
                underlyingDescription: String(describing: error)
            )
        }
    }
}
