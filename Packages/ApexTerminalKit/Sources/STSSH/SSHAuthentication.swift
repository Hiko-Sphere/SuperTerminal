import Foundation
import NIOCore
import NIOSSH
import STCore

/// One round of questions from a server doing keyboard-interactive authentication
/// (RFC 4256).
///
/// The wording belongs to the server and is shown unchanged: RFC 4256 § 3.3 says so, and
/// there is a good reason for it — a client that rewrites "Enter the code from your
/// token" as "Password" has told the user to type the wrong secret.
public struct SSHKeyboardInteractiveChallenge: Sendable, Hashable {
    /// A heading for the exchange, often the PAM service name. Frequently empty.
    public let name: String
    /// Text to show above the prompts. Frequently empty.
    public let instruction: String
    public let prompts: [Prompt]

    public struct Prompt: Sendable, Hashable, Identifiable {
        public let id: Int
        /// The question, exactly as the server wrote it.
        public let prompt: String
        /// Whether what is typed may be shown. `false` means a secret, and the field must
        /// be a secure one.
        public let echo: Bool

        public init(id: Int, prompt: String, echo: Bool) {
            self.id = id
            self.prompt = prompt
            self.echo = echo
        }
    }

    public init(name: String, instruction: String, prompts: [Prompt]) {
        self.name = name
        self.instruction = instruction
        self.prompts = prompts
    }
}

/// Answers one round of questions, in order, or returns `nil` to give up.
///
/// Returning `nil` is a real cancellation and ends the attempt. Sending blank answers
/// instead would look to the server like a wrong password and burn one of the few tries
/// `MaxAuthTries` allows.
public typealias SSHKeyboardInteractiveResponder = @Sendable (SSHKeyboardInteractiveChallenge) async throws -> [String]?

/// One thing ApexTerminal can try in order to authenticate.
public enum SSHCredential: Sendable {
    case password(Redacted<String>)
    case privateKey(SSHPrivateKeyMaterial)
    /// A private key offered together with the certificate an authority issued for it
    /// (D-046). The server checks the certificate against its own CA rather than looking
    /// the key up in an `authorized_keys` file.
    case certifiedKey(SSHPrivateKeyMaterial, SSHCertificate)
    /// The server asks and the person answers, one round at a time (RFC 4256). This is
    /// how one-time codes, PAM stacks and "your password has expired" reach a user.
    case keyboardInteractive(SSHKeyboardInteractiveResponder)
    /// Offered when a server allows unauthenticated access; almost never useful, but
    /// required to interoperate with servers that gate on `none` to advertise methods.
    case none

    var requiredMethod: NIOSSHAvailableUserAuthenticationMethods? {
        switch self {
        case .password: .password
        case .privateKey, .certifiedKey: .publicKey
        case .keyboardInteractive: .keyboardInteractive
        case .none: nil
        }
    }

    /// Non-secret label used in diagnostics and log context. Stays in English so that
    /// log lines and bug reports read the same whatever language the device is set to.
    public var displayKind: String {
        switch self {
        case .password: "password"
        case let .privateKey(material): "key (\(material.algorithm))"
        case let .certifiedKey(material, _): "certificate (\(material.algorithm))"
        case .keyboardInteractive: "keyboard-interactive"
        case .none: "none"
        }
    }

    /// The same distinction as `displayKind`, for the UI's "trying …" state and for
    /// error messages. Kept separate because `displayKind` also travels into logs.
    public var displayName: String {
        switch self {
        case .password: String(localized: "password", bundle: .module)
        case let .privateKey(material): String(localized: "key (\(material.algorithm))", bundle: .module)
        case let .certifiedKey(material, _): String(localized: "certificate (\(material.algorithm))", bundle: .module)
        case .keyboardInteractive: String(localized: "the server's questions", bundle: .module)
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
    private let keyboardInteractiveResponder: SSHKeyboardInteractiveResponder?
    private var offeredKeyboardInteractive = false
    private let log: STLogger
    private let lock = NSLock()
    private var lastOffered: SSHCredential?
    private var attempted: [String] = []

    public init(
        username: String,
        credentials: [SSHCredential],
        passwordProvider: SSHPasswordProvider? = nil,
        keyboardInteractiveResponder: SSHKeyboardInteractiveResponder? = nil,
        log: STLogger = .disabled
    ) {
        self.username = username
        remaining = credentials
        self.passwordProvider = passwordProvider
        self.keyboardInteractiveResponder = keyboardInteractiveResponder
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

        // Nothing stored is left. Keyboard-interactive comes before the plain password
        // fallback, in the order OpenSSH's own client uses: a server offering both is
        // usually asking for the interactive one, because that is the method carrying its
        // second factor, and answering the password prompt alone would fail anyway.
        if !offeredKeyboardInteractive,
            availableMethods.contains(.keyboardInteractive),
            let keyboardInteractiveResponder
        {
            offeredKeyboardInteractive = true
            let credential = SSHCredential.keyboardInteractive(keyboardInteractiveResponder)
            lastOffered = credential
            attempted.append(credential.displayKind)
            log.info("offering credential", ["kind": credential.displayKind])
            nextChallengePromise.succeed(
                NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: credential.asOffer)
            )
            return
        }

        // If the server takes passwords and there is someone to ask, ask — once — and
        // answer the server when the person does. The handshake waits meanwhile; sshd's
        // LoginGraceTime (two minutes by default) is the bound.
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

/// Raised when someone dismisses the server's questions.
public struct SSHKeyboardInteractiveCancelled: Error, Sendable, Equatable {
    public init() {}

    public var stError: STError {
        STError(
            category: .cancelled,
            message: String(localized: "Signing in was cancelled.", bundle: .module),
            recoverySuggestion: String(localized: "Connect again and answer the server's questions.", bundle: .module)
        )
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
        case let .certifiedKey(material, certificate):
            // A certificate that cannot be parsed here has already been refused when it
            // was entered, so falling back to the bare key is the honest thing to do
            // rather than failing the whole attempt: the server may well accept it.
            if let certified = try? certificate.certifiedKey() {
                .privateKey(.init(privateKey: material.key, certifiedKey: certified))
            } else {
                .privateKey(.init(privateKey: material.key))
            }
        case let .keyboardInteractive(responder):
            .keyboardInteractive(
                .init { challenge, promise in
                    // The promise runs the task and takes its result, so the answers cross
                    // no concurrency boundary by hand. The handshake waits meanwhile,
                    // bounded by the server's LoginGraceTime.
                    promise.completeWithTask {
                        let answers = try await responder(
                            SSHKeyboardInteractiveChallenge(
                                name: challenge.name,
                                instruction: challenge.instruction,
                                prompts: challenge.prompts.enumerated().map {
                                    .init(id: $0.offset, prompt: $0.element.prompt, echo: $0.element.echo)
                                }
                            )
                        )
                        guard let answers else {
                            // Cancelled. Failing here ends the attempt now rather than
                            // returning nothing and leaving the connection to sit until
                            // the server's LoginGraceTime expires — measured at 30
                            // seconds of an apparently-hung spinner before this threw.
                            // Nothing is sent either way, so the server still counts no
                            // failed try.
                            throw SSHKeyboardInteractiveCancelled()
                        }
                        return answers
                    }
                }
            )
        case .none:
            .none
        }
    }
}
