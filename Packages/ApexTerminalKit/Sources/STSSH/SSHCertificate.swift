import Foundation
import NIOCore
import NIOSSH
import STCore

/// An OpenSSH certificate: a public key that a certificate authority has signed, with a
/// list of who it speaks for and a window in which it is valid (D-046).
///
/// Certificates are how SSH is run at any size. A user certificate means a server can
/// trust one CA instead of a file of individual keys, and a host certificate means a
/// device can trust a server it has never met without anyone comparing fingerprints —
/// which is the check people skip, so removing the need for it removes a real weakness.
///
/// The certificate is kept as the OpenSSH line it came from and parsed when it is used.
/// It is a public document: a certificate carries no secret, which is why one can be
/// stored beside the connection, synced, and shown in full.
public struct SSHCertificate: Sendable, Equatable, Codable, Hashable {
    /// The `ssh-ed25519-cert-v01@openssh.com AAAA… comment` line, exactly as issued.
    public let openSSHRepresentation: String

    public init(openSSHRepresentation: String) throws {
        let trimmed = openSSHRepresentation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SSHCertificateError.notACertificate }
        self.openSSHRepresentation = trimmed
        // Parsed now so that an unusable certificate is refused where it is entered
        // rather than at the moment someone is trying to connect.
        _ = try certifiedKey()
    }

    /// The parsed certificate.
    public func certifiedKey() throws -> NIOSSHCertifiedPublicKey {
        let key: NIOSSHPublicKey
        do {
            key = try NIOSSHPublicKey(openSSHPublicKey: openSSHRepresentation)
        } catch {
            throw SSHCertificateError.malformed(String(describing: error))
        }
        guard let certified = NIOSSHCertifiedPublicKey(key) else {
            throw SSHCertificateError.notACertificate
        }
        return certified
    }

    // MARK: - What it says

    public var keyID: String { (try? certifiedKey().keyID) ?? "" }

    /// Who the certificate speaks for: user names for a user certificate, host names for
    /// a host one. Empty means "anyone", which OpenSSH allows and which is worth showing
    /// plainly rather than as a blank field.
    public var principals: [String] { (try? certifiedKey().validPrincipals) ?? [] }

    public var kind: Kind {
        guard let type = try? certifiedKey().type else { return .unknown }
        switch type {
        case .user: return .user
        case .host: return .host
        default: return .unknown
        }
    }

    /// `nil` when the certificate is valid from the beginning of time, which is how
    /// `ssh-keygen` records "no start date".
    public var validAfter: Date? {
        guard let seconds = try? certifiedKey().validAfter, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// `nil` when the certificate never expires.
    public var validBefore: Date? {
        guard let seconds = try? certifiedKey().validBefore, seconds < UInt64(Int64.max) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// The fingerprint of the authority that signed it, in the form `ssh-keygen -l`
    /// prints — so it can be compared with what the CA's owner published.
    public var authorityFingerprintSHA256: String {
        guard let signer = try? certifiedKey().signatureKey,
              let host = try? SSHHostKey(signer)
        else { return "" }
        return host.fingerprintSHA256
    }

    public var serial: UInt64 { (try? certifiedKey().serial) ?? 0 }

    /// Whether the certificate is within its window. Checked before offering one, so a
    /// certificate that expired last week is reported as expired rather than as a
    /// rejected login.
    public func isValid(at moment: Date = Date()) -> Bool {
        if let validAfter, moment < validAfter { return false }
        if let validBefore, moment >= validBefore { return false }
        return true
    }

    /// Whether the certificate speaks for `principal`. An empty principal list means the
    /// certificate is valid for any principal, which is OpenSSH's own rule.
    public func permits(principal: String) -> Bool {
        let principals = principals
        return principals.isEmpty || principals.contains(principal)
    }

    public enum Kind: String, Sendable, Equatable, Codable {
        case user
        case host
        case unknown
    }
}

public enum SSHCertificateError: Error, Sendable, Equatable {
    case notACertificate
    case malformed(String)

    public var stError: STError {
        switch self {
        case .notACertificate:
            STError(
                category: .credential,
                message: String(localized: "That is not an OpenSSH certificate.", bundle: .module),
                recoverySuggestion: String(localized: "A certificate looks like a public key but its type ends in `-cert-v01@openssh.com`. It is the file `ssh-keygen -s` writes, usually named `…-cert.pub`.", bundle: .module)
            )
        case let .malformed(detail):
            STError(
                category: .credential,
                message: String(localized: "The certificate could not be read.", bundle: .module),
                underlyingDescription: detail
            )
        }
    }
}

/// A certificate authority this device trusts to vouch for servers (D-046).
///
/// The equivalent of an `@cert-authority` line in `known_hosts`, and deliberately as
/// narrow: a CA is trusted for the hosts its patterns match and no others. A CA trusted
/// for `*` can vouch for any server in the world, which is a decision worth having to
/// type rather than one that happens by default.
public struct SSHCertificateAuthority: Sendable, Equatable, Codable, Identifiable, Hashable {
    public var id: UUID
    /// What the user calls it.
    public var name: String
    /// The authority's public key, as `ssh-keygen -y` or the `.pub` file gives it.
    public var openSSHPublicKey: String
    /// Host patterns this authority may vouch for, in OpenSSH's `known_hosts` style:
    /// `*` matches any run of characters, `?` matches one.
    public var hostPatterns: [String]

    public init(
        id: UUID = UUID(),
        name: String,
        openSSHPublicKey: String,
        hostPatterns: [String]
    ) {
        self.id = id
        self.name = name
        self.openSSHPublicKey = openSSHPublicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.hostPatterns = hostPatterns
    }

    public func publicKey() throws -> NIOSSHPublicKey {
        do {
            return try NIOSSHPublicKey(openSSHPublicKey: openSSHPublicKey)
        } catch {
            throw SSHCertificateError.malformed(String(describing: error))
        }
    }

    public var fingerprintSHA256: String {
        guard let key = try? publicKey(), let host = try? SSHHostKey(key) else { return "" }
        return host.fingerprintSHA256
    }

    /// Whether this authority is trusted for `host`.
    public func vouchesFor(host: String) -> Bool {
        let host = host.lowercased()
        return hostPatterns.contains { Self.matches(pattern: $0.lowercased(), host: host) }
    }

    /// OpenSSH's glob, which is `*` and `?` and nothing else — no character classes, no
    /// alternation. Written out rather than reached for through `NSPredicate`, because a
    /// pattern that quietly means more than it looks like is a security bug.
    static func matches(pattern: String, host: String) -> Bool {
        var patternIndex = pattern.startIndex
        var hostIndex = host.startIndex
        var starPattern: String.Index?
        var starHost: String.Index?

        while hostIndex < host.endIndex {
            if patternIndex < pattern.endIndex,
               pattern[patternIndex] == "?" || pattern[patternIndex] == host[hostIndex] {
                patternIndex = pattern.index(after: patternIndex)
                hostIndex = host.index(after: hostIndex)
            } else if patternIndex < pattern.endIndex, pattern[patternIndex] == "*" {
                starPattern = patternIndex
                starHost = hostIndex
                patternIndex = pattern.index(after: patternIndex)
            } else if let star = starPattern, let resume = starHost {
                patternIndex = pattern.index(after: star)
                hostIndex = host.index(after: resume)
                starHost = hostIndex
            } else {
                return false
            }
        }
        while patternIndex < pattern.endIndex, pattern[patternIndex] == "*" {
            patternIndex = pattern.index(after: patternIndex)
        }
        return patternIndex == pattern.endIndex
    }
}
