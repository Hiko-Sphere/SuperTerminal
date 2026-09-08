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
import NIOCore

/// The six keys RFC 4253 § 7.2 derives from the shared secret, the exchange hash and the
/// session identifier.
///
/// Lifted out of `EllipticCurveKeyExchange` when a second kind of key exchange arrived
/// (the ML-KEM hybrid): this half is identical for every algorithm, and two copies of a
/// key-derivation function is two chances for one of them to drift.
///
/// The caller hands over a hasher that has already absorbed `K` and `H`, because that is
/// the one part that differs — an elliptic-curve exchange encodes `K` as an mpint, while
/// the post-quantum hybrids encode it as a fixed-length string.
enum SessionKeyDerivation {
    static func sessionKeys<Hasher: HashFunction>(
        baseHasher: Hasher,
        sessionID: ByteBuffer,
        role: SSHConnectionRole,
        expectedKeySizes: ExpectedKeySizes
    ) -> NIOSSHSessionKeys {
        // - Initial IV client to server: HASH(K || H || "A" || session_id)
        // - Initial IV server to client: HASH(K || H || "B" || session_id)
        // - Encryption key client to server: HASH(K || H || "C" || session_id)
        // - Encryption key server to client: HASH(K || H || "D" || session_id)
        // - Integrity key client to server: HASH(K || H || "E" || session_id)
        // - Integrity key server to client: HASH(K || H || "F" || session_id)
        func material(_ letter: UnicodeScalar, _ length: Int) -> [UInt8] {
            derive(
                baseHasher: baseHasher,
                discriminatorByte: UInt8(ascii: letter),
                sessionID: sessionID,
                length: length
            )
        }

        let clientToServerIV = material("A", expectedKeySizes.ivSize)
        let serverToClientIV = material("B", expectedKeySizes.ivSize)
        let clientToServerKey = SymmetricKey(data: material("C", expectedKeySizes.encryptionKeySize))
        let serverToClientKey = SymmetricKey(data: material("D", expectedKeySizes.encryptionKeySize))
        let clientToServerMAC = SymmetricKey(data: material("E", expectedKeySizes.macKeySize))
        let serverToClientMAC = SymmetricKey(data: material("F", expectedKeySizes.macKeySize))

        switch role {
        case .client:
            return NIOSSHSessionKeys(
                initialInboundIV: serverToClientIV,
                initialOutboundIV: clientToServerIV,
                inboundEncryptionKey: serverToClientKey,
                outboundEncryptionKey: clientToServerKey,
                inboundMACKey: serverToClientMAC,
                outboundMACKey: clientToServerMAC
            )
        case .server:
            return NIOSSHSessionKeys(
                initialInboundIV: clientToServerIV,
                initialOutboundIV: serverToClientIV,
                inboundEncryptionKey: clientToServerKey,
                outboundEncryptionKey: serverToClientKey,
                inboundMACKey: clientToServerMAC,
                outboundMACKey: serverToClientMAC
            )
        }
    }

    private static func derive<Hasher: HashFunction>(
        baseHasher: Hasher,
        discriminatorByte: UInt8,
        sessionID: ByteBuffer,
        length: Int
    ) -> [UInt8] {
        var localHasher = baseHasher
        localHasher.update(byte: discriminatorByte)
        localHasher.update(data: sessionID.readableBytesView)
        var material = Array(localHasher.finalize())

        while material.count < length {
            var extender = baseHasher
            material.withUnsafeBytes { extender.update(bufferPointer: $0) }
            material.append(contentsOf: Array(extender.finalize()))
        }
        // Truncation: a request shorter than one digest takes a prefix, and one that is
        // not a multiple of the digest size takes a prefix of the last block.
        return Array(material.prefix(length))
    }
}
