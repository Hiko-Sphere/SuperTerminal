import Foundation
import NIOCore
import NIOSSH
import STCore

/// One thing ApexTerminal can try in order to authenticate.
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

    /// Non-secret label used in diagnostics and log context. Stays in English so that
    /// log lines and bug reports read the same whatever language the device is set to.
    public var displayKind: String {
        switch self {
        case .password: "password"
        case let .privateKey(material): "key (\(material.algorithm))"
        case .none: "none"
        }
    }

    /// The same distinction as `displayKind`, for the UI's "trying …" state and for
    /// error messages. Kept separate because `displayKind` also travels into logs.
    public var displayName: String {
        switch self {
        case .password: String(localized: "password", bundle: .module)
        case let .privateKey(material): String(localized: "key (\(material.algorithm))", bundle: .module)
        case .none: String(localized: "none", bundle: .module)
        }
    }
}

/// Asked for a password once the stored credentials are spent and the server has said
/// it takes one. Returns `nil` when the person declines, which ends the attempt.
public typealias SSHPasswordProvider = @Sendable (_ username: String) async throws -> String?

/// Offers credentials in order and reports which one succeeded.
///
/// SSH servers reveal which methods they will accept as authentication proceeds, so
/// this delegate skips offers the server has already ruled out instead of burning
/// attempts against `MaxAuthTries` — a real failure mode that otherwise locks users
/// out after a couple of reconnects.
///
/// With nothing stored (D-024) the caller offers `none` first, so the server says what
/// it takes, and the chain then asks the person for a password — once, and only if the
/// server listed `password`. A key-only server is never asked; a wrong password is not
/// a loop of prompts.
public final class SSHCredentialChain: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private var remaining: [SSHCredential]
    private let passwordProvider: SSHPasswordProvider?
    private var askedForPassword = false
    private let log: STLogger
    private let lock = NSLock()
    private var lastOffered: SSHCredential?
    private var attempted: [String] = []

    public init(
        username: String,
        credentials: [SSHCredential],
        passwordProvider: SSHPasswordProvider? = nil,
        log: STLogger = .disabled
    ) {
        self.username = username
        remaining = credentials
        self.passwordProvider = passwordProvider
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

        // Nothing stored is left. If the server takes passwords and there is someone
        // to ask, ask — once — and answer the server when the person does. The handshake
        // waits meanwhile; sshd's LoginGraceTime (two minutes by default) is the bound.
        if !askedForPassword, availableMethods.contains(.password), let passwordProvider {
            askedForPassword = true
            lastOffered = nil
            let username = username
            let log = log
            log.info("asking for a password", ["methods": "\(availableMethods)"])
            // The promise runs the task and takes its result, so nothing crosses a
            // concurrency boundary by hand.
            nextChallengePromise.completeWithTask { [weak self] in
                guard let password = try await passwordProvider(username) else {
                    self?.record(attempt: "password (cancelled)", offered: nil)
                    throw SSHAuthenticationError.noRemainingCredentials(
                        attempted: self?.attemptedSoFar ?? ["password (cancelled)"]
                    )
                }
                let credential = SSHCredential.password(Redacted(password, label: "ssh-password"))
                self?.record(attempt: "password (typed)", offered: credential)
                log.info("offering credential", ["kind": "password (typed)"])
                return NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: credential.asOffer)
            }
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

    private var attemptedSoFar: [String] {
        lock.lock()
        defer { lock.unlock() }
        return attempted
    }

    private func record(attempt: String, offered: SSHCredential?) {
        lock.lock()
        defer { lock.unlock() }
        attempted.append(attempt)
        lastOffered = offered
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

extension SSHCredential {
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
