import Foundation
import STCore
import STSSH

/// Everything the File Provider extension needs to know about one connection.
///
/// The extension runs in its own process with its own container, so it cannot read the
/// app's host list. Rather than move that list somewhere both processes can write — two
/// writers to one file is a corruption bug waiting to happen — the app publishes this
/// much smaller, read-only projection into the shared App Group whenever the list
/// changes.
///
/// It carries no secret. Credentials stay in the Keychain, referenced here by identifier
/// exactly as ``Host`` references them, so a copy of this file is worth nothing to anyone
/// who obtains it.
public struct SharedDomain: Codable, Sendable, Equatable, Identifiable {
    /// The host's identifier. Also the `NSFileProviderDomain` identifier, so a domain
    /// survives a rename of the connection and disappears with the connection itself.
    public var id: UUID
    /// What Files shows in the sidebar.
    public var displayName: String
    public var hostname: String
    public var port: Int
    /// Never empty in a published domain: a connection that asks for its user name at
    /// connect time cannot be served without someone to ask, so the app refuses to
    /// publish it. See ``SharedDomain/publishability(of:)``.
    public var username: String
    public var transport: Transport
    /// Which stored credentials to offer, in order. Only the ones that need nobody
    /// present are published.
    public var credentials: [Credential]
    /// The directory the domain's root shows. Empty means the login directory, which is
    /// resolved with `realpath(".")` on first use.
    public var rootPath: String

    public init(
        id: UUID,
        displayName: String,
        hostname: String,
        port: Int,
        username: String,
        transport: Transport,
        credentials: [Credential],
        rootPath: String = ""
    ) {
        self.id = id
        self.displayName = displayName
        self.hostname = hostname
        self.port = port
        self.username = username
        self.transport = transport
        self.credentials = credentials
        self.rootPath = rootPath
    }

    public enum Transport: Codable, Sendable, Equatable {
        case directTCP
        case cloudflare(jumpDestination: String?)
    }

    /// A credential the extension can use without anyone being there to answer a prompt.
    ///
    /// There is deliberately no `password(prompt:)` and no passphrase-protected key: the
    /// extension has no way to ask, and a background process that could raise a Face ID
    /// sheet on its own would be worse, not better.
    public enum Credential: Codable, Sendable, Equatable {
        /// A key stored in the Keychain without a passphrase and without biometric
        /// protection.
        case privateKey(id: UUID)
        /// The password saved for this host.
        case storedPassword
    }

    /// The identity host keys are remembered against — the same one the terminal uses,
    /// so a host approved in the app is already approved here and a key that changed is
    /// refused in both places.
    public var knownHostIdentity: KnownHostIdentity {
        switch transport {
        case .directTCP:
            KnownHostIdentity(host: hostname, port: port)
        case let .cloudflare(jumpDestination):
            KnownHostIdentity(host: hostname, port: port, jumpDestination: jumpDestination)
        }
    }
}

/// Why a connection cannot appear in Files, in the words the app shows the user.
///
/// Kept as a value rather than a `Bool` so the toggle can explain itself instead of
/// being mysteriously disabled.
public enum DomainPublishability: Sendable, Equatable {
    case publishable
    /// The connection asks for its user name when it opens (D-024). Nobody is present in
    /// the extension to answer.
    case needsUsername
    /// Every stored credential needs a person: a password that was never saved, a key
    /// with a passphrase, or a key behind Face ID.
    case needsInteractiveCredential
    /// The host key has never been approved. Approving it is a decision only a person
    /// can make, and it has to be made in the app first.
    case hostKeyNotApproved
}
