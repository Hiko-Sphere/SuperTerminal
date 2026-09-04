import Foundation
import STCloudflare
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
    public var port: Int
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

    public enum CredentialReference: Sendable, Codable, Equatable, Hashable {
        /// A private key stored in the Keychain under this identifier.
        case privateKey(id: UUID)
        /// A password stored in the Keychain for this host.
        case password
        /// Offer nothing, for servers that allow unauthenticated access.
        case none
    }

    public init(
        id: UUID = UUID(),
        name: String,
        hostname: String,
        port: Int = 22,
        username: String,
        transport: TransportKind = .directTCP,
        credentials: [CredentialReference] = [],
        folder: String? = nil,
        tags: [String] = [],
        terminalType: String = "xterm-256color",
        environment: [String: String] = [:],
        themeID: String? = nil,
        lastConnected: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.transport = transport
        self.credentials = credentials
        self.folder = folder
        self.tags = tags
        self.terminalType = terminalType
        self.environment = environment
        self.themeID = themeID
        self.lastConnected = lastConnected
    }

    /// The identity host keys are remembered against.
    public var knownHostIdentity: KnownHostIdentity {
        switch transport {
        case .directTCP:
            KnownHostIdentity(host: hostname, port: port)
        case let .cloudflare(jumpDestination):
            // A Cloudflare host is always reached on 443; the port field describes the
            // origin's SSH port, which the tunnel handles.
            KnownHostIdentity(host: hostname, port: 443, jumpDestination: jumpDestination)
        }
    }

    /// A short subtitle for the host list.
    public var subtitle: String {
        switch transport {
        case .directTCP:
            port == 22 ? "\(username)@\(hostname)" : "\(username)@\(hostname):\(port)"
        case let .cloudflare(jumpDestination):
            if let jumpDestination {
                "\(username)@\(hostname) → \(jumpDestination)"
            } else {
                "\(username)@\(hostname)"
            }
        }
    }

    public var validationProblems: [String] {
        var problems: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("Give this connection a name.") }
        if hostname.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("Enter a hostname.") }
        if username.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("Enter a username.") }
        if !(1 ... 65535).contains(port) { problems.append("Port must be between 1 and 65535.") }
        if credentials.isEmpty { problems.append("Choose at least one way to authenticate.") }
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
    /// Whether the stored key material is itself passphrase-encrypted.
    public var isPassphraseProtected: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        algorithm: String,
        publicKeyOpenSSH: String,
        fingerprintSHA256: String,
        createdAt: Date = Date(),
        requiresBiometrics: Bool,
        isPassphraseProtected: Bool
    ) {
        self.id = id
        self.name = name
        self.algorithm = algorithm
        self.publicKeyOpenSSH = publicKeyOpenSSH
        self.fingerprintSHA256 = fingerprintSHA256
        self.createdAt = createdAt
        self.requiresBiometrics = requiresBiometrics
        self.isPassphraseProtected = isPassphraseProtected
    }
}
