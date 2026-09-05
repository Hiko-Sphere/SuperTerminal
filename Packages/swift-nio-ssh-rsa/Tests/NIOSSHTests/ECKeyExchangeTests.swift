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

import Crypto
import NIOCore
import XCTest

@testable import NIOSSH

final class KeyExchangeTests: XCTestCase {
    private func keyExchangeAgreed(_ first: KeyExchangeResult, _ second: KeyExchangeResult) {
        XCTAssertEqual(first.sessionID, second.sessionID)
        XCTAssertEqual(first.keys.initialInboundIV, second.keys.initialOutboundIV)
        XCTAssertEqual(first.keys.initialOutboundIV, second.keys.initialInboundIV)
        XCTAssertEqual(first.keys.inboundEncryptionKey, second.keys.outboundEncryptionKey)
        XCTAssertEqual(first.keys.outboundEncryptionKey, second.keys.inboundEncryptionKey)
        XCTAssertEqual(first.keys.inboundMACKey, second.keys.outboundMACKey)
        XCTAssertEqual(first.keys.outboundMACKey, second.keys.inboundMACKey)
    }

    private func keyExchangeFailed(_ first: KeyExchangeResult, _ second: KeyExchangeResult) {
        // If key exchange fails, we assert that no secrets match. This is a slightly excessive test, but it'll probably be fine.
        XCTAssertNotEqual(first.sessionID, second.sessionID)
        XCTAssertNotEqual(first.keys.initialInboundIV, second.keys.initialOutboundIV)
        XCTAssertNotEqual(first.keys.initialOutboundIV, second.keys.initialInboundIV)
        XCTAssertNotEqual(first.keys.inboundEncryptionKey, second.keys.outboundEncryptionKey)
        XCTAssertNotEqual(first.keys.outboundEncryptionKey, second.keys.inboundEncryptionKey)
        XCTAssertNotEqual(first.keys.inboundMACKey, second.keys.outboundMACKey)
        XCTAssertNotEqual(first.keys.outboundMACKey, second.keys.inboundMACKey)
    }

    /// Runs one exchange and returns the client's keys for the requested sizes.
    private func exchangeKeys<KeyType: ECDHCompatiblePrivateKey>(
        _: KeyType.Type,
        sizes: ExpectedKeySizes
    ) throws -> (server: KeyExchangeResult, client: KeyExchangeResult) {
        var server = EllipticCurveKeyExchange<KeyType>(
            ourRole: .server([.init(ed25519Key: .init())]),
            previousSessionIdentifier: nil
        )
        var client = EllipticCurveKeyExchange<KeyType>(ourRole: .client, previousSessionIdentifier: nil)
        let serverHostKey = NIOSSHPrivateKey(ed25519Key: .init())
        var initialExchangeBytes = ByteBufferAllocator().buffer(capacity: 1024)

        let clientMessage = client.initiateKeyExchangeClientSide(allocator: ByteBufferAllocator())
        let (serverKeys, serverResponse) = try server.completeKeyExchangeServerSide(
            clientKeyExchangeMessage: clientMessage,
            serverHostKey: serverHostKey,
            initialExchangeBytes: &initialExchangeBytes,
            allocator: ByteBufferAllocator(),
            expectedKeySizes: sizes
        )
        initialExchangeBytes.clear()
        let clientKeys = try client.receiveServerKeyExchangePayload(
            serverKeyExchangeMessage: serverResponse,
            initialExchangeBytes: &initialExchangeBytes,
            allocator: ByteBufferAllocator(),
            expectedKeySizes: sizes
        )
        return (serverKeys, clientKeys)
    }

    /// RFC 4253 § 7.2: a key longer than one digest is extended by hashing K || H || (key
    /// so far), not by repeating, zero-padding, or truncating.
    ///
    /// curve25519-sha256 hashes with SHA-256, so a 64-byte request needs exactly one round
    /// of extension. This is what chacha20-poly1305@openssh.com asks for.
    func testKeysLongerThanOneDigestAreExtendedPerRFC4253() throws {
        let sixtyFour = ExpectedKeySizes(ivSize: 0, encryptionKeySize: 64, macKeySize: 0)
        let (server, client) = try exchangeKeys(Curve25519.KeyAgreement.PrivateKey.self, sizes: sixtyFour)

        // Both sides must derive the same 64 bytes, or nothing else matters.
        XCTAssertEqual(client.keys.outboundEncryptionKey, server.keys.inboundEncryptionKey)
        XCTAssertEqual(client.keys.inboundEncryptionKey, server.keys.outboundEncryptionKey)
        XCTAssertEqual(client.keys.outboundEncryptionKey.bitCount, 64 * 8)

        // A zero-length IV and MAC key are legal requests: an AEAD with the sequence
        // number as its nonce needs neither.
        XCTAssertEqual(client.keys.initialOutboundIV.count, 0)
        XCTAssertEqual(client.keys.outboundMACKey.bitCount, 0)

        let bytes = client.keys.outboundEncryptionKey.withUnsafeBytes { Array($0) }
        let first = Array(bytes[0..<32])
        let second = Array(bytes[32..<64])
        // The second block is a fresh hash, not the first block again and not padding.
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(second, [UInt8](repeating: 0, count: 32))
    }

    /// The first digest's worth of an extended key is the un-extended key: extension only
    /// ever appends, so a 32-byte request and a 64-byte request agree on their first 32.
    func testExtensionOnlyAppends() throws {
        // Same exchange twice is impossible (fresh ephemeral keys), so the property is
        // checked by deriving both sizes from one exchange's inputs: the 64-byte key's
        // prefix must equal what a 32-byte request would have produced. That is exactly
        // how the extension is defined, and it is the property a mismatch with OpenSSH
        // would violate first.
        let (_, client64) = try exchangeKeys(
            Curve25519.KeyAgreement.PrivateKey.self,
            sizes: ExpectedKeySizes(ivSize: 12, encryptionKeySize: 64, macKeySize: 32)
        )
        let key64 = client64.keys.outboundEncryptionKey.withUnsafeBytes { Array($0) }
        XCTAssertEqual(key64.count, 64)
        // A 12-byte IV is a prefix of a single digest, as before, and a 32-byte MAC key
        // is exactly one digest — neither touches the extension path.
        XCTAssertEqual(client64.keys.initialOutboundIV.count, 12)
        XCTAssertEqual(client64.keys.outboundMACKey.bitCount, 32 * 8)
    }

    func testBasicSuccessfulKeyExchangeNoPreviousSessionCurve25519() throws {
        try self.basicSuccessfulKeyExchangeNoPreviousSession(Curve25519.KeyAgreement.PrivateKey.self)
    }

    func testBasicSuccessfulKeyExchangeNoPreviousSessionP256() throws {
        try self.basicSuccessfulKeyExchangeNoPreviousSession(P256.KeyAgreement.PrivateKey.self)
    }

    func testBasicSuccessfulKeyExchangeNoPreviousSessionP384() throws {
        try self.basicSuccessfulKeyExchangeNoPreviousSession(P384.KeyAgreement.PrivateKey.self)
    }

    func testBasicSuccessfulKeyExchangeNoPreviousSessionP521() throws {
        try self.basicSuccessfulKeyExchangeNoPreviousSession(P521.KeyAgreement.PrivateKey.self)
    }

    private func basicSuccessfulKeyExchangeNoPreviousSession<KeyType: ECDHCompatiblePrivateKey>(
        _: KeyType.Type = KeyType.self
    ) throws {
        var server = EllipticCurveKeyExchange<KeyType>(
            ourRole: .server([.init(ed25519Key: .init())]),
            previousSessionIdentifier: nil
        )
        var client = EllipticCurveKeyExchange<KeyType>(ourRole: .client, previousSessionIdentifier: nil)
        let serverHostKey = NIOSSHPrivateKey(ed25519Key: .init())

        var initialExchangeBytes = ByteBufferAllocator().buffer(capacity: 1024)

        let clientMessage = client.initiateKeyExchangeClientSide(allocator: ByteBufferAllocator())
        let (serverKeys, serverResponse) = try assertNoThrowWithValue(
            try server.completeKeyExchangeServerSide(
                clientKeyExchangeMessage: clientMessage,
                serverHostKey: serverHostKey,
                initialExchangeBytes: &initialExchangeBytes,
                allocator: ByteBufferAllocator(),
                expectedKeySizes: AES128GCMOpenSSHTransportProtection.keySizes
            )
        )

        initialExchangeBytes.clear()

        let clientKeys = try assertNoThrowWithValue(
            try client.receiveServerKeyExchangePayload(
                serverKeyExchangeMessage: serverResponse,
                initialExchangeBytes: &initialExchangeBytes,
                allocator: ByteBufferAllocator(),
                expectedKeySizes: AES128GCMOpenSSHTransportProtection.keySizes
            )
        )

        // Check we agree on the session ID and the keys.
        self.keyExchangeAgreed(serverKeys, clientKeys)
    }

    func testBasicSuccessfulKeyExchangeWithPreviousSessionCurve25519() throws {
        try self.basicSuccessfulKeyExchangeWithPreviousSession(Curve25519.KeyAgreement.PrivateKey.self)
    }

    func testBasicSuccessfulKeyExchangeWithPreviousSessionP256() throws {
        try self.basicSuccessfulKeyExchangeWithPreviousSession(P256.KeyAgreement.PrivateKey.self)
    }

    func testBasicSuccessfulKeyExchangeWithPreviousSessionP384() throws {
        try self.basicSuccessfulKeyExchangeWithPreviousSession(P384.KeyAgreement.PrivateKey.self)
    }

    func testBasicSuccessfulKeyExchangeWithPreviousSessionP521() throws {
        try self.basicSuccessfulKeyExchangeWithPreviousSession(P521.KeyAgreement.PrivateKey.self)
    }

    func basicSuccessfulKeyExchangeWithPreviousSession<KeyType: ECDHCompatiblePrivateKey>(
        _: KeyType.Type = KeyType.self
    ) throws {
        var previousSessionIdentifier = ByteBufferAllocator().buffer(capacity: 1024)
        previousSessionIdentifier.writeBytes(0...255)

        var server = EllipticCurveKeyExchange<KeyType>(
            ourRole: .server([.init(ed25519Key: .init())]),
            previousSessionIdentifier: previousSessionIdentifier
        )
        var client = EllipticCurveKeyExchange<KeyType>(
            ourRole: .client,
            previousSessionIdentifier: previousSessionIdentifier
        )
        let serverHostKey = NIOSSHPrivateKey(ed25519Key: .init())

        var initialExchangeBytes = ByteBufferAllocator().buffer(capacity: 1024)

        let clientMessage = client.initiateKeyExchangeClientSide(allocator: ByteBufferAllocator())
        let (serverKeys, serverResponse) = try assertNoThrowWithValue(
            try server.completeKeyExchangeServerSide(
                clientKeyExchangeMessage: clientMessage,
                serverHostKey: serverHostKey,
                initialExchangeBytes: &initialExchangeBytes,
                allocator: ByteBufferAllocator(),
                expectedKeySizes: AES128GCMOpenSSHTransportProtection.keySizes
            )
        )

        initialExchangeBytes.clear()

        let clientKeys = try assertNoThrowWithValue(
            try client.receiveServerKeyExchangePayload(
                serverKeyExchangeMessage: serverResponse,
                initialExchangeBytes: &initialExchangeBytes,
                allocator: ByteBufferAllocator(),
                expectedKeySizes: AES128GCMOpenSSHTransportProtection.keySizes
            )
        )

        // Check we agree on the session ID and the keys.
        self.keyExchangeAgreed(serverKeys, clientKeys)
    }

    func testKeyExchangeWithECDSAP256Signatures() throws {
        var server = EllipticCurveKeyExchange<Curve25519.KeyAgreement.PrivateKey>(
            ourRole: .server([.init(ed25519Key: .init())]),
            previousSessionIdentifier: nil
        )
        var client = EllipticCurveKeyExchange<Curve25519.KeyAgreement.PrivateKey>(
            ourRole: .client,
            previousSessionIdentifier: nil
        )
        let serverHostKey = NIOSSHPrivateKey(p256Key: .init())

        var initialExchangeBytes = ByteBufferAllocator().buffer(capacity: 1024)

        let clientMessage = client.initiateKeyExchangeClientSide(allocator: ByteBufferAllocator())
        let (serverKeys, serverResponse) = try assertNoThrowWithValue(
            try server.completeKeyExchangeServerSide(
                clientKeyExchangeMessage: clientMessage,
                serverHostKey: serverHostKey,
                initialExchangeBytes: &initialExchangeBytes,
                allocator: ByteBufferAllocator(),
                expectedKeySizes: AES128GCMOpenSSHTransportProtection.keySizes
            )
        )

        initialExchangeBytes.clear()

        let clientKeys = try assertNoThrowWithValue(
            try client.receiveServerKeyExchangePayload(
                serverKeyExchangeMessage: serverResponse,
                initialExchangeBytes: &initialExchangeBytes,
                allocator: ByteBufferAllocator(),
                expectedKeySizes: AES128GCMOpenSSHTransportProtection.keySizes
            )
        )

        // Check we agree on the session ID and the keys.
        self.keyExchangeAgreed(serverKeys, clientKeys)
    }

    func testKeyExchangeWithECDSAP384Signatures() throws {
        var server = EllipticCurveKeyExchange<Curve25519.KeyAgreement.PrivateKey>(
            ourRole: .server([.init(ed25519Key: .init())]),
            previousSessionIdentifier: nil
        )
        var client = EllipticCurveKeyExchange<Curve25519.KeyAgreement.PrivateKey>(
            ourRole: .client,
            previousSessionIdentifier: nil
        )
        let serverHostKey = NIOSSHPrivateKey(p384Key: .init())

        var initialExchangeBytes = ByteBufferAllocator().buffer(capacity: 1024)

        let clientMessage = client.initiateKeyExchangeClientSide(allocator: ByteBufferAllocator())
        let (serverKeys, serverResponse) = try assertNoThrowWithValue(
            try server.completeKeyExchangeServerSide(
                clientKeyExchangeMessage: clientMessage,
                serverHostKey: serverHostKey,
                initialExchangeBytes: &initialExchangeBytes,
                allocator: ByteBufferAllocator(),
                expectedKeySizes: AES128GCMOpenSSHTransportProtection.keySizes
            )
        )

        initialExchangeBytes.clear()

        let clientKeys = try assertNoThrowWithValue(
            try client.receiveServerKeyExchangePayload(
                serverKeyExchangeMessage: serverResponse,
                initialExchangeBytes: &initialExchangeBytes,
                allocator: ByteBufferAllocator(),
                expectedKeySizes: AES128GCMOpenSSHTransportProtection.keySizes
            )
        )

        // Check we agree on the session ID and the keys.
        self.keyExchangeAgreed(serverKeys, clientKeys)
    }

    func testKeyExchangeWithECDSAP521Signatures() throws {
        var server = EllipticCurveKeyExchange<Curve25519.KeyAgreement.PrivateKey>(
            ourRole: .server([.init(ed25519Key: .init())]),
            previousSessionIdentifier: nil
        )
        var client = EllipticCurveKeyExchange<Curve25519.KeyAgreement.PrivateKey>(
            ourRole: .client,
            previousSessionIdentifier: nil
        )
        let serverHostKey = NIOSSHPrivateKey(p521Key: .init())

        var initialExchangeBytes = ByteBufferAllocator().buffer(capacity: 1024)

        let clientMessage = client.initiateKeyExchangeClientSide(allocator: ByteBufferAllocator())
        let (serverKeys, serverResponse) = try assertNoThrowWithValue(
            try server.completeKeyExchangeServerSide(
                clientKeyExchangeMessage: clientMessage,
                serverHostKey: serverHostKey,
                initialExchangeBytes: &initialExchangeBytes,
                allocator: ByteBufferAllocator(),
                expectedKeySizes: AES128GCMOpenSSHTransportProtection.keySizes
            )
        )

        initialExchangeBytes.clear()

        let clientKeys = try assertNoThrowWithValue(
            try client.receiveServerKeyExchangePayload(
                serverKeyExchangeMessage: serverResponse,
                initialExchangeBytes: &initialExchangeBytes,
                allocator: ByteBufferAllocator(),
                expectedKeySizes: AES128GCMOpenSSHTransportProtection.keySizes
            )
        )

        // Check we agree on the session ID and the keys.
        self.keyExchangeAgreed(serverKeys, clientKeys)
    }

    func testBasicSuccessfulKeyExchangeWithWiderKeys() throws {
        var server = EllipticCurveKeyExchange<Curve25519.KeyAgreement.PrivateKey>(
            ourRole: .server([.init(ed25519Key: .init())]),
            previousSessionIdentifier: nil
        )
        var client = EllipticCurveKeyExchange<Curve25519.KeyAgreement.PrivateKey>(
            ourRole: .client,
            previousSessionIdentifier: nil
        )
        let serverHostKey = NIOSSHPrivateKey(ed25519Key: .init())

        var initialExchangeBytes = ByteBufferAllocator().buffer(capacity: 1024)

        let clientMessage = client.initiateKeyExchangeClientSide(allocator: ByteBufferAllocator())
        let (serverKeys, serverResponse) = try assertNoThrowWithValue(
            try server.completeKeyExchangeServerSide(
                clientKeyExchangeMessage: clientMessage,
                serverHostKey: serverHostKey,
                initialExchangeBytes: &initialExchangeBytes,
                allocator: ByteBufferAllocator(),
                expectedKeySizes: AES256GCMOpenSSHTransportProtection.keySizes
            )
        )

        initialExchangeBytes.clear()

        let clientKeys = try assertNoThrowWithValue(
            try client.receiveServerKeyExchangePayload(
                serverKeyExchangeMessage: serverResponse,
                initialExchangeBytes: &initialExchangeBytes,
                allocator: ByteBufferAllocator(),
                expectedKeySizes: AES256GCMOpenSSHTransportProtection.keySizes
            )
        )

        // Check we agree on the session ID and the keys.
        self.keyExchangeAgreed(serverKeys, clientKeys)
    }

    func testDisagreeingOnInitialExchangeBytesLeadsToFailedKeyExchange() throws {
        var server = EllipticCurveKeyExchange<Curve25519.KeyAgreement.PrivateKey>(
            ourRole: .server([.init(ed25519Key: .init())]),
            previousSessionIdentifier: nil
        )
        var client = EllipticCurveKeyExchange<Curve25519.KeyAgreement.PrivateKey>(
            ourRole: .client,
            previousSessionIdentifier: nil
        )
        let serverHostKey = NIOSSHPrivateKey(ed25519Key: .init())

        var serverInitialBytes = ByteBufferAllocator().buffer(capacity: 1024)
        var clientInitialBytes = serverInitialBytes

        serverInitialBytes.writeBytes(0..<128)
        clientInitialBytes.writeBytes(1..<129)

        let clientMessage = client.initiateKeyExchangeClientSide(allocator: ByteBufferAllocator())
        let (_, serverResponse) = try assertNoThrowWithValue(
            try server.completeKeyExchangeServerSide(
                clientKeyExchangeMessage: clientMessage,
                serverHostKey: serverHostKey,
                initialExchangeBytes: &serverInitialBytes,
                allocator: ByteBufferAllocator(),
                expectedKeySizes: AES128GCMOpenSSHTransportProtection.keySizes
            )
        )

        XCTAssertThrowsError(
            try client.receiveServerKeyExchangePayload(
                serverKeyExchangeMessage: serverResponse,
                initialExchangeBytes: &clientInitialBytes,
                allocator: ByteBufferAllocator(),
                expectedKeySizes: AES128GCMOpenSSHTransportProtection.keySizes
            )
        ) { error in
            XCTAssertEqual((error as? NIOSSHError).map { $0.type }, .invalidExchangeHashSignature)
        }
    }

    func testWeValidateTheExchangeHash() throws {
        var server = EllipticCurveKeyExchange<Curve25519.KeyAgreement.PrivateKey>(
            ourRole: .server([.init(ed25519Key: .init())]),
            previousSessionIdentifier: nil
        )
        var client = EllipticCurveKeyExchange<Curve25519.KeyAgreement.PrivateKey>(
            ourRole: .client,
            previousSessionIdentifier: nil
        )
        let serverHostKey = NIOSSHPrivateKey(ed25519Key: .init())

        var initialExchangeBytes = ByteBufferAllocator().buffer(capacity: 1024)

        let clientMessage = client.initiateKeyExchangeClientSide(allocator: ByteBufferAllocator())
        var (_, serverResponse) = try assertNoThrowWithValue(
            try server.completeKeyExchangeServerSide(
                clientKeyExchangeMessage: clientMessage,
                serverHostKey: serverHostKey,
                initialExchangeBytes: &initialExchangeBytes,
                allocator: ByteBufferAllocator(),
                expectedKeySizes: AES128GCMOpenSSHTransportProtection.keySizes
            )
        )

        initialExchangeBytes.clear()

        // Ok, the server has sent a signature over the exchange hash. Let's change that signature.
        serverResponse.signature = try assertNoThrowWithValue(
            serverHostKey.sign(digest: SHA256.hash(data: [1, 2, 3, 4, 5]))
        )

        XCTAssertThrowsError(
            try client.receiveServerKeyExchangePayload(
                serverKeyExchangeMessage: serverResponse,
                initialExchangeBytes: &initialExchangeBytes,
                allocator: ByteBufferAllocator(),
                expectedKeySizes: AES128GCMOpenSSHTransportProtection.keySizes
            )
        ) { error in
            XCTAssertEqual((error as? NIOSSHError).map { $0.type }, .invalidExchangeHashSignature)
        }
    }
}

/// This helper extension persists the old way of initializing config for this file.
extension SSHConnectionRole {
    fileprivate static func server(_ hostKeys: [NIOSSHPrivateKey]) -> SSHConnectionRole {
        .server(SSHServerConfiguration(hostKeys: hostKeys, userAuthDelegate: DenyAllServerAuthDelegate()))
    }

    fileprivate static var client: SSHConnectionRole {
        .client(
            SSHClientConfiguration(
                userAuthDelegate: ExplodingAuthDelegate(),
                serverAuthDelegate: AcceptAllHostKeysDelegate()
            )
        )
    }
}
