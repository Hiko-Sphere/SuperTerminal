import Crypto
import Foundation
import NIOCore
import NIOSSH
import STCore

/// A server host key in the form ApexTerminal stores and shows to people.
///
/// Fingerprints use the OpenSSH SHA-256 spelling (`SHA256:` followed by unpadded
/// base64) so that what the app displays can be compared character-for-character with
/// `ssh-keygen -lf` output on the server. A fingerprint the user cannot cross-check
/// against the server is not a security control, it is decoration.
public struct SSHHostKey: Sendable, Equatable, Hashable, Codable {
    /// The SSH algorithm name, e.g. `ssh-ed25519`.
    public let algorithm: String
    /// The raw SSH wire encoding of the public key.
    public let blob: Data

    public init(algorithm: String, blob: Data) {
        self.algorithm = algorithm
        self.blob = blob
    }

    public init(_ key: NIOSSHPublicKey) throws {
        let openSSH = String(openSSHPublicKey: key)
        let parts = openSSH.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else {
            throw STError(
                category: .hostKey,
                message: String(localized: "The server sent a host key this app could not decode.", bundle: .module),
                underlyingDescription: "unexpected OpenSSH public key encoding"
            )
        }
        algorithm = String(parts[0])
        self.blob = blob
    }

    /// `SHA256:<unpadded-base64>`, matching `ssh-keygen -l`.
    public var fingerprintSHA256: String {
        let digest = SHA256.hash(data: blob)
        let base64 = Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:\(base64)"
    }

    /// The `authorized_keys`-style single-line encoding.
    public var openSSHRepresentation: String {
        "\(algorithm) \(blob.base64EncodedString())"
    }

    /// Parses an `authorized_keys` / `known_hosts` style line: `<algorithm> <base64> [comment]`.
    public init(openSSHLine: String) throws {
        let parts = openSSHLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else {
            throw STError(
                category: .hostKey,
                message: String(localized: "That is not a valid OpenSSH public key line.", bundle: .module),
                underlyingDescription: "expected \"<algorithm> <base64>\""
            )
        }
        algorithm = String(parts[0])
        self.blob = blob
    }

    public func asNIOSSHPublicKey() throws -> NIOSSHPublicKey {
        try NIOSSHPublicKey(openSSHPublicKey: openSSHRepresentation)
    }
}

/// The identity a host key is remembered against.
///
/// Port is part of the identity because `example.com:22` and `example.com:2222` are
/// routinely different machines. Cloudflare-tunnelled hosts additionally carry the
/// jump destination, so one Access hostname fronting several bastion targets does not
/// collapse their host keys into one entry.
public struct KnownHostIdentity: Sendable, Hashable, Codable {
    public let host: String
    public let port: Int
    public let jumpDestination: String?

    public init(host: String, port: Int, jumpDestination: String? = nil) {
        self.host = host.lowercased()
        self.port = port
        self.jumpDestination = jumpDestination?.lowercased()
    }

    public var storageKey: String {
        if let jumpDestination {
            "\(host):\(port)/\(jumpDestination)"
        } else {
            "\(host):\(port)"
        }
    }

    /// How the identity is shown in the UI.
    public var displayName: String {
        if let jumpDestination {
            "\(host) → \(jumpDestination)"
        } else if port == 22 {
            host
        } else {
            "\(host):\(port)"
        }
    }
}

/// A remembered host key.
public struct KnownHostEntry: Sendable, Equatable, Codable {
    public let identity: KnownHostIdentity
    public let key: SSHHostKey
    public let firstSeen: Date
    public var lastSeen: Date

    public init(identity: KnownHostIdentity, key: SSHHostKey, firstSeen: Date, lastSeen: Date) {
        self.identity = identity
        self.key = key
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}

/// What the verifier decided about a presented host key.
public enum HostKeyVerdict: Sendable, Equatable {
    /// The key matches what was recorded for this identity.
    case known(KnownHostEntry)
    /// This identity has never been seen. The user must confirm the fingerprint.
    case unknown(KnownHostIdentity, SSHHostKey)
    /// A key is recorded for this identity and it is **not** the one presented.
    case changed(expected: KnownHostEntry, presented: SSHHostKey)
}
