//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

@preconcurrency import Crypto
import _CryptoExtras
import NIOCore

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// An SSH private key.
///
/// This object identifies a single SSH entity, usually a server. It is used as part of the SSH handshake and key exchange process,
/// and is also presented to clients that want to validate that they are communicating with the appropriate server. Clients use
/// this key to sign data in order to validate their identity as part of user auth.
///
/// Users cannot do much with this key other than construct it, but NIO uses it internally.
public struct NIOSSHPrivateKey: Sendable {
    /// The actual key structure used to perform the key operations.
    internal var backingKey: BackingKey

    private init(backingKey: BackingKey) {
        self.backingKey = backingKey
    }

    public init(ed25519Key key: Curve25519.Signing.PrivateKey) {
        self.backingKey = .ed25519(key)
    }

    public init(p256Key key: P256.Signing.PrivateKey) {
        self.backingKey = .ecdsaP256(key)
    }

    public init(p384Key key: P384.Signing.PrivateKey) {
        self.backingKey = .ecdsaP384(key)
    }

    public init(p521Key key: P521.Signing.PrivateKey) {
        self.backingKey = .ecdsaP521(key)
    }

    #if canImport(Darwin)
    public init(secureEnclaveP256Key key: SecureEnclave.P256.Signing.PrivateKey) {
        self.backingKey = .secureEnclaveP256(key)
    }
    #endif

    /// Creates a private key from RSA key material.
    public init(rsaKey key: _RSA.Signing.PrivateKey) {
        self.backingKey = .rsa(key)
    }

    // The algorithms that apply to this host key.
    internal var hostKeyAlgorithms: [Substring] {
        switch self.backingKey {
        case .ed25519:
            return ["ssh-ed25519"]
        case .ecdsaP256:
            return ["ecdsa-sha2-nistp256"]
        case .ecdsaP384:
            return ["ecdsa-sha2-nistp384"]
        case .ecdsaP521:
            return ["ecdsa-sha2-nistp521"]
        case .rsa:
            // Only SHA-512 is advertised for a *host* key. `sign(digest:)` has no way to
            // learn which variant was negotiated, so offering both would let a peer pick
            // SHA-256 and then receive a SHA-512 signature. Advertising one makes the
            // negotiated algorithm and the signing algorithm the same by construction.
            // Client-side user auth is unaffected: it chooses and declares its own
            // algorithm, and verification accepts either.
            return ["rsa-sha2-512"]
        #if canImport(Darwin)
        case .secureEnclaveP256:
            return ["ecdsa-sha2-nistp256"]
        #endif
        }
    }
}

extension NIOSSHPrivateKey {
    /// The various key types that can be used with NIOSSH.
    internal enum BackingKey {
        case ed25519(Curve25519.Signing.PrivateKey)
        case ecdsaP256(P256.Signing.PrivateKey)
        case ecdsaP384(P384.Signing.PrivateKey)
        case ecdsaP521(P521.Signing.PrivateKey)
        case rsa(_RSA.Signing.PrivateKey)

        #if canImport(Darwin)
        case secureEnclaveP256(SecureEnclave.P256.Signing.PrivateKey)
        #endif
    }
}

extension NIOSSHPrivateKey {
    func sign<DigestBytes: Digest>(digest: DigestBytes) throws -> NIOSSHSignature {
        switch self.backingKey {
        case .ed25519(let key):
            let signature = try digest.withUnsafeBytes { ptr in
                try key.signature(for: ptr)
            }
            return NIOSSHSignature(backingSignature: .ed25519(.data(signature)))
        case .ecdsaP256(let key):
            let signature = try digest.withUnsafeBytes { ptr in
                try key.signature(for: ptr)
            }
            return NIOSSHSignature(backingSignature: .ecdsaP256(signature))
        case .ecdsaP384(let key):
            let signature = try digest.withUnsafeBytes { ptr in
                try key.signature(for: ptr)
            }
            return NIOSSHSignature(backingSignature: .ecdsaP384(signature))
        case .ecdsaP521(let key):
            let signature = try digest.withUnsafeBytes { ptr in
                try key.signature(for: ptr)
            }
            return NIOSSHSignature(backingSignature: .ecdsaP521(signature))

        case .rsa(let key):
            // Matches the single algorithm `hostKeyAlgorithms` advertises for RSA.
            let algorithm = NIOSSHRSASignatureAlgorithm.sha512
            let signature = try digest.withUnsafeBytes { ptr in
                try algorithm.signature(for: Array(ptr), using: key)
            }
            return NIOSSHSignature(backingSignature: .rsa(algorithm: algorithm, bytes: .data(signature)))
        #if canImport(Darwin)
        case .secureEnclaveP256(let key):
            let signature = try digest.withUnsafeBytes { ptr in
                try key.signature(for: ptr)
            }
            return NIOSSHSignature(backingSignature: .ecdsaP256(signature))
        #endif
        }
    }

    /// Signs a user authentication payload.
    ///
    /// - Parameter rsaAlgorithm: which RSA variant to use. Ignored for every other key
    ///   type. It must match the algorithm name written into the request and into the
    ///   signed payload, or the server will reject the signature.
    func sign(
        _ payload: UserAuthSignablePayload,
        rsaAlgorithm: NIOSSHRSASignatureAlgorithm = .sha512
    ) throws -> NIOSSHSignature {
        switch self.backingKey {
        case .ed25519(let key):
            let signature = try key.signature(for: payload.bytes.readableBytesView)
            return NIOSSHSignature(backingSignature: .ed25519(.data(signature)))
        case .ecdsaP256(let key):
            let signature = try key.signature(for: payload.bytes.readableBytesView)
            return NIOSSHSignature(backingSignature: .ecdsaP256(signature))
        case .ecdsaP384(let key):
            let signature = try key.signature(for: payload.bytes.readableBytesView)
            return NIOSSHSignature(backingSignature: .ecdsaP384(signature))
        case .ecdsaP521(let key):
            let signature = try key.signature(for: payload.bytes.readableBytesView)
            return NIOSSHSignature(backingSignature: .ecdsaP521(signature))
        case .rsa(let key):
            let signature = try rsaAlgorithm.signature(
                for: Array(payload.bytes.readableBytesView),
                using: key
            )
            return NIOSSHSignature(backingSignature: .rsa(algorithm: rsaAlgorithm, bytes: .data(signature)))
        #if canImport(Darwin)
        case .secureEnclaveP256(let key):
            let signature = try key.signature(for: payload.bytes.readableBytesView)
            return NIOSSHSignature(backingSignature: .ecdsaP256(signature))
        #endif
        }
    }
}

extension NIOSSHPrivateKey {
    /// Signs bytes the peer chose, and writes the signature in SSH wire format.
    ///
    /// This exists for one caller: an SSH **agent**, which by definition signs a blob it
    /// cannot inspect. `SSH_AGENTC_SIGN_REQUEST` (draft-miller-ssh-agent § 4.5) hands over
    /// an opaque string that is, in practice, some other connection's user-auth payload —
    /// the agent cannot tell which server it is for, and that is the risk agent forwarding
    /// carries rather than a shortcoming of this method.
    ///
    /// It is named for that purpose so it cannot be reached for by accident. Nothing in
    /// normal authentication should use it: the paths that sign a payload this library
    /// itself constructed are the ones to prefer, because they know what they are signing.
    ///
    /// - Parameter rsaAlgorithm: which RSA variant to use, ignored for other key types.
    ///   The name is written into the signature, so it must match what the caller declares.
    public func signOpaqueAgentRequest(
        _ data: ByteBuffer,
        rsaAlgorithm: NIOSSHRSASignatureAlgorithm = .sha512
    ) throws -> ByteBuffer {
        let signature = try self.sign(UserAuthSignablePayload(bytes: data), rsaAlgorithm: rsaAlgorithm)
        var buffer = ByteBufferAllocator().buffer(capacity: 128)
        buffer.writeCompositeSSHString { $0.writeSSHSignature(signature) }
        return buffer
    }

    /// The public half in the SSH wire encoding an agent puts in its identities answer.
    public var publicKeyBlob: ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: 128)
        buffer.writeCompositeSSHString { $0.writeSSHHostKey(self.publicKey) }
        // The composite string wrote a length prefix; the agent wants the blob itself.
        buffer.moveReaderIndex(forwardBy: 4)
        return buffer
    }

    /// Obtains the public key for a corresponding private key.
    public var publicKey: NIOSSHPublicKey {
        switch self.backingKey {
        case .ed25519(let privateKey):
            return NIOSSHPublicKey(backingKey: .ed25519(privateKey.publicKey))
        case .ecdsaP256(let privateKey):
            return NIOSSHPublicKey(backingKey: .ecdsaP256(privateKey.publicKey))
        case .ecdsaP384(let privateKey):
            return NIOSSHPublicKey(backingKey: .ecdsaP384(privateKey.publicKey))
        case .ecdsaP521(let privateKey):
            return NIOSSHPublicKey(backingKey: .ecdsaP521(privateKey.publicKey))
        case .rsa(let privateKey):
            return NIOSSHPublicKey(backingKey: .rsa(privateKey.publicKey))
        #if canImport(Darwin)
        case .secureEnclaveP256(let privateKey):
            return NIOSSHPublicKey(backingKey: .ecdsaP256(privateKey.publicKey))
        #endif
        }
    }
}
