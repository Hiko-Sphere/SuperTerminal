import Foundation
import NIOCore
import NIOSSH
import STCore

/// One thing SuperTerminal can try in order to authenticate.
public enum SSHCredential: Sendable {
    case password(Redacted<String>)
    case privateKey(SSHPrivateKeyMaterial)
    /// Offered when a server allows unauthenticated access; almost never useful, but
    /// required to interoperate with servers that gate on `none` to advertise methods.
    case none

    var requiredMethod: NIOSSHAvailableUserAuthenticationMethods? {
        switch self {
        case .password: .password
        case .privateKey: .publicKey
        case .none: nil
        }
    }

    /// Non-secret label used in diagnostics and in the UI's "trying …" state.
    public var displayKind: String {
        switch self {
        case .password: "password"
        case let .privateKey(material): "key (\(material.algorithm))"
        case .none: "none"
        }
    }
}

/// Offers credentials in order and reports which one succeeded.
///
/// SSH servers reveal which methods they will accept as authentication proceeds, so
/// this delegate skips offers the server has already ruled out instead of burning
/// attempts against `MaxAuthTries` — a real failure mode that otherwise locks users
/// out after a couple of reconnects.
public final class SSHCredentialChain: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private var remaining: [SSHCredential]
    private let log: STLogger
    private let lock = NSLock()
    private var lastOffered: SSHCredential?
    private var attempted: [String] = []

    public init(username: String, credentials: [SSHCredential], log: STLogger = .disabled) {
        self.username = username
        remaining = credentials
        self.log = log.child(subsystem: "ssh.auth")
    }

    /// The credential most recently offered, so a failure can be attributed.
    public var mostRecentlyOffered: SSHCredential? {
        lock.lock()
        defer { lock.unlock() }
        return lastOffered
    }

    public func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        lock.lock()
        defer { lock.unlock() }

        while !remaining.isEmpty {
            let candidate = remaining.removeFirst()
            if let required = candidate.requiredMethod, !availableMethods.contains(required) {
                log.debug("skipping credential the server will not accept", ["kind": candidate.displayKind])
                continue
            }
            lastOffered = candidate
            attempted.append(candidate.displayKind)
            log.info("offering credential", ["kind": candidate.displayKind])
            nextChallengePromise.succeed(
                NIOSSHUserAuthenticationOffer(
                    username: username,
                    serviceName: "",
                    offer: candidate.asOffer
                )
            )
            return
        }

        // No offers left. Failing the promise ends the handshake immediately.
        //
        // Succeeding with `nil` instead would leave the connection idle until the
        // server's LoginGraceTime expires — two minutes of an apparently-hung
        // "Connecting…" spinner before the user learns their key was wrong.
        lastOffered = nil
        nextChallengePromise.fail(SSHAuthenticationError.noRemainingCredentials(attempted: attempted))
    }
}

/// Raised when the credential chain runs out of things to offer.
public struct SSHAuthenticationError: Error, Sendable, Equatable {
    /// Human-readable kinds of the credentials that were actually offered, in order.
    public let attempted: [String]

    public static func noRemainingCredentials(attempted: [String]) -> SSHAuthenticationError {
        SSHAuthenticationError(attempted: attempted)
    }
}

private extension SSHCredential {
    var asOffer: NIOSSHUserAuthenticationOffer.Offer {
        switch self {
        case let .password(secret):
            .password(.init(password: secret.reveal()))
        case let .privateKey(material):
            .privateKey(.init(privateKey: material.key))
        case .none:
            .none
        }
    }
}
