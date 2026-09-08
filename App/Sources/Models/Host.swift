import Foundation
import STCloudflare
import STForwarding
import STSSH

/// A saved connection.
///
/// The model deliberately holds no secret. Passwords and private keys live in the
/// Keychain and are referenced by identifier, so exporting, syncing or backing up a host
/// list can never carry credentials with it.
public struct Host: Identifiable, Sendable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var hostname: String
    /// The port the connection is made to: the SSH port for a direct connection, the
    /// Cloudflare edge's HTTPS port (443 unless published otherwise) through a tunnel.
    public var port: Int
    /// May be empty: the connection then asks for a user name when it opens (D-024).
    public var username: String
    /// How the connection reaches the server.
    public var transport: TransportKind
    /// Which stored credential to offer, in order.
    public var credentials: [CredentialReference]
    public var folder: String?
    public var tags: [String]
    /// Terminal type advertised to the remote host.
    public var terminalType: String
    /// Environment variables to request. Servers usually allowlist these.
    public var environment: [String: String]
    public var themeID: String?
    public var lastConnected: Date?
    /// Only meaningful for a Cloudflare transport. The service token itself lives in the
    /// Keychain of the device it was entered on and never syncs; a synced record that
    /// says `.serviceToken` asks for the token again on the other device.
    public var accessAuthentication: AccessAuthentication?
    /// The platform the user set by hand, which always wins over what was detected.
    public var platformOverride: HostPlatform?
    /// The platform the server last reported (D-019). Optional in the record so that a
    /// record written before the field existed still decodes.
    public var detectedPlatform: HostPlatform?
    /// Screen sharing as it used to be configured, inside the SSH connection (D-022).
    ///
    /// Screens are their own connections now (D-027). This is kept only so that records
    /// written before that — and records arriving from a device still on the old version —
    /// decode and can be migrated. Nothing writes it; `ScreenMigration` empties it.
    public var vnc: VNCSettings?
    /// What the app treats the server as: the hand-set value, else the detected one.
    public var effectivePlatform: HostPlatform? { platformOverride ?? detectedPlatform }

    public var usesServiceToken: Bool { accessAuthentication == .serviceToken }
    /// Port-forwarding rules saved with this connection (D-045). Optional so records
    /// written before the feature existed still decode.
    public var portForwards: [PortForward]?
    /// Whether this server appears in the Files app (D-044).
    ///
    /// Optional so records written before the feature existed still decode, and `nil`
    /// reads as off: a connection is never published to Files without being asked for.
    public var showsInFiles: Bool?
    /// Whether the connection is published to Files right now.
    public var isPublishedToFiles: Bool { showsInFiles ?? false }
    /// When this record last changed, on any device. Drives last-writer-wins in sync.
    ///
    /// Optional on purpose: files written before sync existed have no such field, and a
    /// synthesized decoder throws on a missing key unless the property is optional. `nil`
    /// means "never stamped", which sync treats as older than anything.
    public var modifiedAt: Date?

    public enum TransportKind: Sendable, Codable, Equatable {
        /// A direct TCP connection to `hostname:port`.
        case directTCP
        /// Through a Cloudflare Tunnel, optionally behind Access.
        ///
        /// `jumpDestination` is set when the tunnel is configured as a bastion, in which
        /// case the hostname addresses the bastion and this addresses the final server.
        case cloudflare(jumpDestination: String?)

        public var isCloudflare: Bool {
            if case .cloudflare = self { return true }
            return false
        }
    }

    /// How a tunnelled connection authenticates to Cloudflare Access. `nil` on records
    /// written before this existed, meaning the browser login.
    public enum AccessAuthentication: String, Sendable, Codable, Equatable {
        case browserLogin
        case serviceToken
    }

    public enum CredentialReference: Sendable, Codable, Equatable, Hashable {
        /// A private key stored in the Keychain under this identifier.
        case privateKey(id: UUID)
        /// A password stored in the Keychain for this host.
        case password
        /// Offer nothing, for servers that allow unauthenticated access.
        case none
    }

    /// How to reach the server's screen. `port` is the VNC port; through SSH it is the
    /// port as the server sees it, on `targetHost` — the server itself when nil, so a
    /// desktop behind the same bastion as the shell needs nothing exposed.
    public struct VNCSettings: Sendable, Codable, Equatable {
        public var port: Int
        /// A `direct-tcpip` channel over the SSH connection (the default), or plain TCP.
        public var viaSSH: Bool
        public var targetHost: String?
        /// Whether a VNC password is in the Keychain for this connection. The password
        /// itself never enters the record.
        public var hasPassword: Bool

        public init(port: Int = 5900, viaSSH: Bool = true, targetHost: String? = nil, hasPassword: Bool = false) {
            self.port = port
            self.viaSSH = viaSSH
            self.targetHost = targetHost
            self.hasPassword = hasPassword
        }
    }

    public init(
        id: UUID = UUID(),
        name: String,
        hostname: String,
        /// Omitted means the transport's default: 22 for a direct connection, 443 for the
        /// Cloudflare edge. A fixed 22 here would have any Cloudflare host built in code
        /// — rather than through the editor — dial the edge on the SSH port.
        port: Int? = nil,
        username: String,
        transport: TransportKind = .directTCP,
        credentials: [CredentialReference] = [],
        folder: String? = nil,
        tags: [String] = [],
        terminalType: String = "xterm-256color",
        environment: [String: String] = [:],
        themeID: String? = nil,
        lastConnected: Date? = nil,
        accessAuthentication: AccessAuthentication? = nil,
        platformOverride: HostPlatform? = nil,
        detectedPlatform: HostPlatform? = nil,
        showsInFiles: Bool? = nil,
        portForwards: [PortForward]? = nil
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port ?? Self.defaultPort(for: transport)
        self.username = username
        self.transport = transport
        self.credentials = credentials
        self.folder = folder
        self.tags = tags
        self.terminalType = terminalType
        self.environment = environment
        self.themeID = themeID
        self.lastConnected = lastConnected
        self.accessAuthentication = accessAuthentication
        self.platformOverride = platformOverride
        self.detectedPlatform = detectedPlatform
        self.showsInFiles = showsInFiles
        self.portForwards = portForwards
    }

    /// The identity host keys are remembered against.
    public var knownHostIdentity: KnownHostIdentity {
        switch transport {
        case .directTCP:
            KnownHostIdentity(host: hostname, port: port)
        case let .cloudflare(jumpDestination):
            KnownHostIdentity(host: hostname, port: port, jumpDestination: jumpDestination)
        }
    }

    /// The port a transport uses when the field is left blank.
    public static func defaultPort(for transport: TransportKind) -> Int {
        transport.isCloudflare ? 443 : 22
    }

    /// A short subtitle for the host list: `user@host`, the port when it is not the
    /// default, and no user at all when none is saved.
    public var subtitle: String {
        let account = username.isEmpty ? hostname : "\(username)@\(hostname)"
        let address = port == Self.defaultPort(for: transport) ? account : "\(account):\(port)"
        switch transport {
        case .directTCP:
            return address
        case let .cloudflare(jumpDestination):
            if let jumpDestination { return "\(address) → \(jumpDestination)" }
            return address
        }
    }

    public var validationProblems: [String] {
        var problems: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { problems.append(String(localized: "Give this connection a name.")) }
        if hostname.trimmingCharacters(in: .whitespaces).isEmpty { problems.append(String(localized: "Enter a hostname.")) }
        if !(1 ... 65535).contains(port) { problems.append(String(localized: "Port must be between 1 and 65535.")) }
        return problems
    }
}

/// A private key the user has imported or generated.
public struct StoredKey: Identifiable, Sendable, Codable, Equatable {
    public var id: UUID
    public var name: String
    /// SSH algorithm name, e.g. `ssh-ed25519`.
    public var algorithm: String
    /// The public half, so the key can be shown, copied to a server and identified
    /// without unlocking the private half.
    public var publicKeyOpenSSH: String
    public var fingerprintSHA256: String
    public var createdAt: Date
    /// Whether reading the private key requires a biometric or passcode check.
    public var requiresBiometrics: Bool
    public var modifiedAt: Date?
    /// Whether the stored key material is itself passphrase-encrypted.
    public var isPassphraseProtected: Bool
    /// Whether the private key itself is in iCloud Keychain. The metadata above syncs
    /// through CloudKit regardless; this says whether another device will also have the
    /// secret, or only know the key exists. Optional so records written before sync
    /// existed still decode.
    public var secretInICloud: Bool?

    public init(
        id: UUID = UUID(),
        name: String,
        algorithm: String,
        publicKeyOpenSSH: String,
        fingerprintSHA256: String,
        createdAt: Date = Date(),
        requiresBiometrics: Bool,
        isPassphraseProtected: Bool,
        secretInICloud: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.algorithm = algorithm
        self.publicKeyOpenSSH = publicKeyOpenSSH
        self.fingerprintSHA256 = fingerprintSHA256
        self.createdAt = createdAt
        self.requiresBiometrics = requiresBiometrics
        self.isPassphraseProtected = isPassphraseProtected
        self.secretInICloud = secretInICloud
    }
}
