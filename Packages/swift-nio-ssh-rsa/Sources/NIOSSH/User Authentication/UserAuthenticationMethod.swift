//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
import NIOCore

/// The user authentication modes available at this point in time.
///
/// User authentication in SSH proceeds in a dynamic fashion, and it is possible to require multiple forms
/// of authentication sequentially, or to be able to accept one of many forms.
public struct NIOSSHAvailableUserAuthenticationMethods: OptionSet, Sendable {
    public var rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// Public key authentication is acceptable.
    public static let publicKey: NIOSSHAvailableUserAuthenticationMethods = .init(rawValue: 1 << 0)

    /// Password-based authentication is acceptable.
    public static let password: NIOSSHAvailableUserAuthenticationMethods = .init(rawValue: 1 << 1)

    /// Host-based authentication is acceptable.
    public static let hostBased: NIOSSHAvailableUserAuthenticationMethods = .init(rawValue: 1 << 2)

    /// RFC 4256 keyboard-interactive authentication is acceptable: the server asks
    /// questions and the client answers them, which is how one-time codes, PAM stacks and
    /// expired-password changes reach a user.
    public static let keyboardInteractive: NIOSSHAvailableUserAuthenticationMethods = .init(rawValue: 1 << 3)

    /// A short-hand for all supported authentication types.
    ///
    /// Deliberately without `keyboardInteractive`: a server advertises this set, and this
    /// library implements only the *client* half of RFC 4256. Offering a method that will
    /// then be refused spends one of the client's few attempts for nothing.
    public static let all: NIOSSHAvailableUserAuthenticationMethods = [.publicKey, .password, .hostBased]

    /// Everything a client may try before the server has said what it accepts.
    ///
    /// The first offer is made blind — the server does not list its methods until it has
    /// refused something — so this is wider than ``all`` and includes keyboard-interactive.
    static let allClientMethods: NIOSSHAvailableUserAuthenticationMethods = [
        .publicKey, .password, .hostBased, .keyboardInteractive,
    ]
}

extension NIOSSHAvailableUserAuthenticationMethods {
    internal init(_ message: SSHMessage.UserAuthFailureMessage) {
        self = .init()

        for message in message.authentications {
            switch message {
            case "publickey":
                self.insert(.publicKey)
            case "password":
                self.insert(.password)
            case "hostbased":
                self.insert(.hostBased)
            case "keyboard-interactive":
                self.insert(.keyboardInteractive)
            default:
                // This is an unknown method, which we ignore.
                break
            }
        }
    }

    internal var strings: [Substring] {
        guard self != .init() else {
            return []
        }

        // We need an array.
        var methods = [Substring]()
        methods.reserveCapacity(4)

        if self.contains(.password) {
            methods.append("password")
        }
        if self.contains(.publicKey) {
            methods.append("publickey")
        }
        if self.contains(.hostBased) {
            methods.append("hostbased")
        }
        if self.contains(.keyboardInteractive) {
            methods.append("keyboard-interactive")
        }

        return methods
    }
}

extension NIOSSHAvailableUserAuthenticationMethods: Hashable {}

/// A specific request for user authentication. This type is the one observed from the server side. The
/// associated client side type is ``NIOSSHUserAuthenticationOffer``.
public struct NIOSSHUserAuthenticationRequest: Sendable {
    /// The username for which the client would like to authenticate.
    public var username: String

    /// The specific authentication request.
    public var request: Request

    public init(username: String, serviceName: String, request: Request) {
        self.username = username
        self.request = request
    }
}

extension NIOSSHUserAuthenticationRequest {
    /// ``NIOSSHUserAuthenticationRequest/Request-swift.enum`` describes the kind of authentication attempt the client is making.
    public enum Request: Sendable {
        /// The client would like to perform public key authentication.
        case publicKey(PublicKey)

        /// The client would like to perform password authentication.
        case password(Password)

        /// The client would like to perform host-based authentication.
        ///
        /// This method is currently unsupported by ``NIOSSH``.
        case hostBased(HostBased)

        /// The client believes it does not need authentication.
        case none
    }
}

extension NIOSSHUserAuthenticationRequest.Request {
    /// Information provided by the client when attempting to perform a public-key authentication.
    public struct PublicKey: Sendable {
        /// The user's public key.
        public var publicKey: NIOSSHPublicKey

        public init(publicKey: NIOSSHPublicKey) {
            self.publicKey = publicKey
        }
    }

    /// Information provided by the client when attempting to perform password-based authentication.
    public struct Password: Sendable {
        /// The user's password.
        public var password: String

        public init(password: String) {
            self.password = password
        }
    }

    /// Information provided by the client when attempting to perform host-based authentication.
    ///
    /// This method is currently unsupported by ``NIOSSH``.
    public struct HostBased: Sendable {
        init() {
            fatalError("PublicKeyRequest is currently unimplemented")
        }
    }
}

extension NIOSSHUserAuthenticationRequest: Hashable {}

extension NIOSSHUserAuthenticationRequest.Request: Hashable {}

extension NIOSSHUserAuthenticationRequest.Request.PublicKey: Hashable {}

extension NIOSSHUserAuthenticationRequest.Request.Password: Hashable {}

extension NIOSSHUserAuthenticationRequest.Request.HostBased: Hashable {}

/// A specific offer of user authentication. This type is the one used on the client side. The
/// associated server side type is ``NIOSSHUserAuthenticationRequest``.
public struct NIOSSHUserAuthenticationOffer: Sendable {
    /// The username for which the client would like to authenticate.
    public var username: String

    /// The specific authentication offer.
    public var offer: Offer

    public init(username: String, serviceName: String, offer: Offer) {
        self.username = username
        self.offer = offer
    }
}

extension NIOSSHUserAuthenticationOffer {
    /// ``NIOSSHUserAuthenticationOffer/Offer-swift.enum`` describes the kind of authentication offer the client is making.
    public enum Offer: Sendable {
        /// The client would like to perform private key authentication.
        case privateKey(PrivateKey)

        /// The client would like to perform password authentication.
        case password(Password)

        /// The client would like to perform host-based authentication.
        ///
        /// This method is currently unsupported by ``NIOSSH``.
        case hostBased(HostBased)

        /// The client would like to answer the server's questions (RFC 4256).
        case keyboardInteractive(KeyboardInteractive)

        /// The client believes it does not need authentication.
        case none
    }
}

/// One round of questions from a server doing keyboard-interactive authentication.
///
/// A round can carry no prompts at all — RFC 4256 § 3.3 uses that to display a message —
/// and a server may send several rounds before deciding.
public struct NIOSSHKeyboardInteractiveChallenge: Sendable, Hashable {
    /// A heading for the exchange, often the PAM service name, often empty.
    public var name: String

    /// Text to show before the prompts, often empty.
    public var instruction: String

    public var prompts: [Prompt]

    public struct Prompt: Sendable, Hashable {
        /// The question, exactly as the server wrote it. RFC 4256 § 3.3 requires that the
        /// client show it unchanged: a client that invents its own wording can turn "Enter
        /// the code from your token" into "Password".
        public var prompt: String

        /// Whether what the user types may be shown. False means a secret.
        public var echo: Bool

        public init(prompt: String, echo: Bool) {
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

extension NIOSSHUserAuthenticationOffer.Offer {
    /// Information provided by the client when attempting to perform private key authentication.
    public struct PrivateKey: Sendable {
        /// The client's private key.
        ///
        /// This is not sent to the server, but is used by ``NIOSSH`` to respond to auth challenges.
        public var privateKey: NIOSSHPrivateKey

        /// The client's public key.
        ///
        /// This is sent to the server.
        public var publicKey: NIOSSHPublicKey

        public init(privateKey: NIOSSHPrivateKey) {
            self.privateKey = privateKey
            self.publicKey = privateKey.publicKey
        }

        public init(privateKey: NIOSSHPrivateKey, certifiedKey: NIOSSHCertifiedPublicKey) {
            self.privateKey = privateKey
            self.publicKey = NIOSSHPublicKey(certifiedKey)
        }
    }

    /// Information provided by the client when attempting to perform password-based authentication.
    public struct Password: Sendable {
        /// The client's password.
        public var password: String

        public init(password: String) {
            self.password = password
        }
    }

    /// Information provided by the client when attempting to perform host-based authentication.
    ///
    /// This method is currently unsupported by ``NIOSSH``.
    public struct HostBased: Sendable {
        init() {
            fatalError("PublicKeyRequest is currently unimplemented")
        }
    }

    /// How the client answers the server's questions.
    ///
    /// Unlike the other offers this one carries no secret. It carries a way to *obtain*
    /// answers, because the questions are not known until the server asks them and a
    /// person usually has to read them — so `respond` is given a promise rather than being
    /// expected to answer at once.
    public struct KeyboardInteractive: Sendable {
        /// Called for each round the server sends. Fulfil the promise with one answer per
        /// prompt, in order, or with `nil` to abandon the attempt — which is what a
        /// cancelled prompt means, and it fails the authentication rather than sending
        /// empty strings the server would reject anyway.
        public typealias Responder = @Sendable (
            NIOSSHKeyboardInteractiveChallenge,
            EventLoopPromise<[String]?>
        ) -> Void

        /// The submethods the client is willing to be asked for, as RFC 4256 § 3.1
        /// describes. Empty — the usual value — means "whatever the server chooses".
        public var submethods: String

        public var respond: Responder

        public init(submethods: String = "", respond: @escaping Responder) {
            self.submethods = submethods
            self.respond = respond
        }
    }
}

extension SSHMessage.UserAuthRequestMessage {
    init(request: NIOSSHUserAuthenticationOffer, sessionID: ByteBuffer) throws {
        // We only ever ask for the ssh-connection service.
        self.username = request.username
        self.service = "ssh-connection"

        switch request.offer {
        case .privateKey(let privateKeyRequest):
            // For RSA the algorithm name and the key blob's identifier differ, and the
            // same algorithm name must appear in three places: the request, the signed
            // payload, and the signature itself. Choosing it once here is what keeps them
            // consistent.
            let rsaAlgorithm = NIOSSHRSASignatureAlgorithm.sha512
            let algorithmName = privateKeyRequest.publicKey.signatureAlgorithmNames.first
                ?? String(privateKeyRequest.publicKey.keyPrefix)
            let dataToSign = UserAuthSignablePayload(
                sessionIdentifier: sessionID,
                userName: self.username,
                serviceName: self.service,
                publicKey: privateKeyRequest.publicKey,
                algorithmName: algorithmName
            )
            let signature = try privateKeyRequest.privateKey.sign(dataToSign, rsaAlgorithm: rsaAlgorithm)
            self.method = .publicKey(.known(key: privateKeyRequest.publicKey, signature: signature))
        case .password(let passwordRequest):
            self.method = .password(passwordRequest.password)
        case .hostBased:
            fatalError("Unsupported")
        case .keyboardInteractive(let request):
            // The language tag is deprecated by RFC 4256 § 3.1 and must be empty.
            self.method = .keyboardInteractive(languageTag: "", submethods: request.submethods)
        case .none:
            self.method = .none
        }
    }
}

/// The outcome of a user authentication attempt.
public enum NIOSSHUserAuthenticationOutcome: Sendable {
    /// The authentication attempt succeeded and the client is authenticated.
    case success

    /// The authentication attempt partially succeeded, but additional authentication is required.
    ///
    /// The additional authentication requirements are described in `remainingMethods`.
    case partialSuccess(remainingMethods: NIOSSHAvailableUserAuthenticationMethods)

    /// The authentication attempt failed.
    case failure
}

enum NIOSSHUserAuthenticationResponseMessage {
    case success
    case failure(SSHMessage.UserAuthFailureMessage)
    case publicKeyOK(SSHMessage.UserAuthPKOKMessage)
    case disconnect(SSHMessage.DisconnectMessage)
}

extension NIOSSHUserAuthenticationResponseMessage {
    init(_ outcome: NIOSSHUserAuthenticationOutcome, supportedMethods: NIOSSHAvailableUserAuthenticationMethods) {
        switch outcome {
        case .success:
            self = .success
        case .partialSuccess(remainingMethods: let remaining):
            let message = SSHMessage.UserAuthFailureMessage(authentications: remaining.strings, partialSuccess: true)
            self = .failure(message)
        case .failure:
            let message = SSHMessage.UserAuthFailureMessage(
                authentications: supportedMethods.strings,
                partialSuccess: false
            )
            self = .failure(message)
        }
    }
}
