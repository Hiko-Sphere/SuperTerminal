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
import Crypto
import Foundation
import NIOCore

#if canImport(CryptoKit)
import CryptoKit
#endif

/// `mlkem768x25519-sha256`: X25519 and ML-KEM-768 together, as OpenSSH implements it.
///
/// The point of a hybrid is that it is no weaker than either half. An attacker has to
/// break *both* X25519 and ML-KEM-768 to recover the session key, so adopting it costs
/// nothing if the post-quantum half turns out to be flawed, and protects traffic recorded
/// today against a quantum computer built later — which matters for SSH, where a captured
/// session is worth decrypting years after the fact.
///
/// ML-KEM comes from CryptoKit, which is Apple's own FIPS 203 implementation. No primitive
/// is written here: this file is the SSH plumbing around one, and nothing more.
///
/// Two details differ from the elliptic-curve exchanges and are the whole reason this is a
/// separate type rather than another curve:
///
/// * The public values are concatenations. `Q_C` is the ML-KEM encapsulation key followed
///   by the X25519 public key; `Q_S` is the ML-KEM ciphertext followed by the server's
///   X25519 public key. The X25519 half is always the last 32 bytes, which is how each is
///   split without depending on a remembered constant for the other half.
/// * `K` is a hash of the two shared secrets, `SHA-256(K_PQ ‖ K_X25519)`, and it is fed to
///   the exchange hash and the key derivation **as a string** — a four-byte length and the
///   thirty-two bytes — rather than as the mpint an elliptic-curve exchange uses. Getting
///   that wrong produces a handshake that completes locally and fails against every real
///   server, which is why the tests run against OpenSSH rather than against this code's
///   own idea of what it should produce.
@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
struct MLKEM768X25519KeyExchange: EllipticCurveKeyExchangeProtocol {
    static var keyExchangeAlgorithmNames: [Substring] { ["mlkem768x25519-sha256"] }

    /// The X25519 half is always the last 32 bytes of either public value.
    private static let x25519KeySize = 32

    private var ourRole: SSHConnectionRole
    private var previousSessionIdentifier: ByteBuffer?

    private var x25519: Curve25519.KeyAgreement.PrivateKey
    /// The client's decapsulation key. Nil on the server, which never has one.
    private var decapsulationKey: CryptoKit.MLKEM768.PrivateKey?

    private var ourPublicValue: ByteBuffer?
    private var theirPublicValue: ByteBuffer?
    private var sharedSecret: SHA256Digest?

    init(ourRole: SSHConnectionRole, previousSessionIdentifier: ByteBuffer?) {
        self.ourRole = ourRole
        self.previousSessionIdentifier = previousSessionIdentifier
        x25519 = Curve25519.KeyAgreement.PrivateKey()
        // Only a client generates a decapsulation key; the server encapsulates against
        // the one the client sends. A failure here would mean CryptoKit could not produce
        // a key at all, which is not a condition this exchange can proceed through.
        decapsulationKey = ourRole.isClient ? try? CryptoKit.MLKEM768.PrivateKey() : nil
    }

    // MARK: - Client

    func initiateKeyExchangeClientSide(allocator: ByteBufferAllocator) -> SSHMessage.KeyExchangeECDHInitMessage {
        precondition(ourRole.isClient, "Only clients may initiate key exchange")
        guard let decapsulationKey else {
            preconditionFailure("A client without a decapsulation key cannot offer this exchange")
        }
        let encapsulationKey = decapsulationKey.publicKey.rawRepresentation
        var buffer = allocator.buffer(capacity: encapsulationKey.count + Self.x25519KeySize)
        buffer.writeBytes(encapsulationKey)
        buffer.writeBytes(x25519.publicKey.rawRepresentation)
        return SSHMessage.KeyExchangeECDHInitMessage(publicKey: buffer)
    }

    mutating func receiveServerKeyExchangePayload(
        serverKeyExchangeMessage message: SSHMessage.KeyExchangeECDHReplyMessage,
        initialExchangeBytes: inout ByteBuffer,
        allocator: ByteBufferAllocator,
        expectedKeySizes: ExpectedKeySizes
    ) throws -> KeyExchangeResult {
        precondition(ourRole.isClient, "Only clients may receive a server key exchange packet!")
        guard let decapsulationKey else {
            throw NIOSSHError.invalidKeySize
        }

        let serverValue = message.publicKey
        let (ciphertext, serverX25519) = try Self.split(serverValue)
        theirPublicValue = serverValue

        // The post-quantum half, then the classical one. Both must succeed: a hybrid whose
        // classical half was skipped is not a hybrid.
        let postQuantum = try decapsulationKey.decapsulate(ciphertext)
        let classical = try x25519.sharedSecretFromKeyAgreement(
            with: try Curve25519.KeyAgreement.PublicKey(rawRepresentation: serverX25519)
        )

        var combiner = SHA256()
        postQuantum.withUnsafeBytes { combiner.update(bufferPointer: $0) }
        classical.withUnsafeBytes { combiner.update(bufferPointer: $0) }
        let secret = combiner.finalize()
        sharedSecret = secret

        let result = try finalize(
            serverHostKey: message.hostKey,
            initialExchangeBytes: &initialExchangeBytes,
            allocator: allocator,
            expectedKeySizes: expectedKeySizes
        )

        guard message.hostKey.isValidSignature(message.signature, for: result.exchangeHash) else {
            throw NIOSSHError.invalidExchangeHashSignature
        }
        return KeyExchangeResult(sessionID: result.sessionID, keys: result.keys)
    }

    // MARK: - Server

    mutating func completeKeyExchangeServerSide(
        clientKeyExchangeMessage message: SSHMessage.KeyExchangeECDHInitMessage,
        serverHostKey: NIOSSHPrivateKey,
        initialExchangeBytes: inout ByteBuffer,
        allocator: ByteBufferAllocator,
        expectedKeySizes: ExpectedKeySizes
    ) throws -> (KeyExchangeResult, SSHMessage.KeyExchangeECDHReplyMessage) {
        precondition(ourRole.isServer, "Only servers may receive a client key exchange packet!")

        let clientValue = message.publicKey
        let (encapsulationKeyBytes, clientX25519) = try Self.split(clientValue)
        theirPublicValue = clientValue

        let encapsulationKey = try CryptoKit.MLKEM768.PublicKey(rawRepresentation: encapsulationKeyBytes)
        let encapsulated = try encapsulationKey.encapsulate()
        let classical = try x25519.sharedSecretFromKeyAgreement(
            with: try Curve25519.KeyAgreement.PublicKey(rawRepresentation: clientX25519)
        )

        var combiner = SHA256()
        encapsulated.sharedSecret.withUnsafeBytes { combiner.update(bufferPointer: $0) }
        classical.withUnsafeBytes { combiner.update(bufferPointer: $0) }
        sharedSecret = combiner.finalize()

        var ours = allocator.buffer(capacity: encapsulated.encapsulated.count + Self.x25519KeySize)
        ours.writeBytes(encapsulated.encapsulated)
        ours.writeBytes(x25519.publicKey.rawRepresentation)
        ourPublicValue = ours

        let result = try finalize(
            serverHostKey: serverHostKey.publicKey,
            initialExchangeBytes: &initialExchangeBytes,
            allocator: allocator,
            expectedKeySizes: expectedKeySizes
        )
        let signature = try serverHostKey.sign(digest: result.exchangeHash)

        return (
            KeyExchangeResult(sessionID: result.sessionID, keys: result.keys),
            SSHMessage.KeyExchangeECDHReplyMessage(
                hostKey: serverHostKey.publicKey,
                publicKey: ours,
                signature: signature
            )
        )
    }

    // MARK: - Shared

    /// Splits a public value into its post-quantum half and its X25519 half.
    ///
    /// From the end, because the X25519 key is the fixed-size part: an encapsulation key
    /// and a ciphertext are different lengths, and neither needs to be spelled out here.
    private static func split(_ buffer: ByteBuffer) throws -> (postQuantum: Data, x25519: Data) {
        guard buffer.readableBytes > x25519KeySize else { throw NIOSSHError.invalidKeySize }
        let bytes = Array(buffer.readableBytesView)
        let boundary = bytes.count - x25519KeySize
        return (Data(bytes[..<boundary]), Data(bytes[boundary...]))
    }

    private struct Result {
        var sessionID: ByteBuffer
        var exchangeHash: SHA256Digest
        var keys: NIOSSHSessionKeys
    }

    private mutating func finalize(
        serverHostKey: NIOSSHPublicKey,
        initialExchangeBytes: inout ByteBuffer,
        allocator: ByteBufferAllocator,
        expectedKeySizes: ExpectedKeySizes
    ) throws -> Result {
        guard let sharedSecret else { throw NIOSSHError.invalidKeySize }

        // The client's own public value is not kept when it initiates, because the message
        // carries it; rebuilt here so both roles hash the same two strings in the same
        // order.
        if ourPublicValue == nil, let decapsulationKey {
            var buffer = allocator.buffer(capacity: 1216)
            buffer.writeBytes(decapsulationKey.publicKey.rawRepresentation)
            buffer.writeBytes(x25519.publicKey.rawRepresentation)
            ourPublicValue = buffer
        }
        guard let ourPublicValue, let theirPublicValue else { throw NIOSSHError.invalidKeySize }

        initialExchangeBytes.writeCompositeSSHString {
            $0.writeSSHHostKey(serverHostKey)
        }
        switch ourRole {
        case .client:
            initialExchangeBytes.writeSSHString(ourPublicValue.readableBytesView)
            initialExchangeBytes.writeSSHString(theirPublicValue.readableBytesView)
        case .server:
            initialExchangeBytes.writeSSHString(theirPublicValue.readableBytesView)
            initialExchangeBytes.writeSSHString(ourPublicValue.readableBytesView)
        }

        var hasher = SHA256()
        hasher.update(data: initialExchangeBytes.readableBytesView)
        Self.absorbAsSSHString(sharedSecret, into: &hasher)
        let exchangeHash = hasher.finalize()

        let sessionID: ByteBuffer
        if let previousSessionIdentifier {
            sessionID = previousSessionIdentifier
        } else {
            var hashBytes = allocator.buffer(capacity: SHA256Digest.byteCount)
            hashBytes.writeBytes(Array(exchangeHash))
            sessionID = hashBytes
        }

        // `K` as a string again, for the same reason.
        var baseHasher = SHA256()
        Self.absorbAsSSHString(sharedSecret, into: &baseHasher)
        exchangeHash.withUnsafeBytes { baseHasher.update(bufferPointer: $0) }

        let keys = SessionKeyDerivation.sessionKeys(
            baseHasher: baseHasher,
            sessionID: sessionID,
            role: ourRole,
            expectedKeySizes: expectedKeySizes
        )
        return Result(sessionID: sessionID, exchangeHash: exchangeHash, keys: keys)
    }
}

@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
extension MLKEM768X25519KeyExchange {
    /// Absorbs the shared secret the way SSH writes a string: a four-byte big-endian
    /// length, then the bytes.
    ///
    /// The post-quantum hybrids encode `K` this way rather than as an mpint, because `K`
    /// is the output of a hash rather than a number — there is no sign bit to worry about
    /// and no leading zero to strip. An mpint here produces a handshake that agrees with
    /// itself and with nothing else.
    fileprivate static func absorbAsSSHString(_ secret: SHA256Digest, into hasher: inout SHA256) {
        var length = UInt32(SHA256Digest.byteCount).bigEndian
        withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
        secret.withUnsafeBytes { hasher.update(bufferPointer: $0) }
    }
}
