//===----------------------------------------------------------------------===//
//
// Added by SuperTerminal. Not part of upstream swift-nio-ssh.
//
// See patches/niossh-rsa.patch and DECISIONS.md D-007 in the SuperTerminal
// repository for why this exists and what maintaining it obliges.
//
//===----------------------------------------------------------------------===//

import Crypto
import Foundation
import NIOCore
import _CryptoExtras

/// The RSA signature algorithms this library supports.
///
/// SHA-1 `ssh-rsa` is deliberately absent. OpenSSH disabled it by default in 8.8 because
/// SHA-1 chosen-prefix collisions are practical, and supporting it would mean shipping a
/// downgrade a server could ask for.
public enum NIOSSHRSASignatureAlgorithm: String, Sendable, Hashable, CaseIterable {
    case sha256 = "rsa-sha2-256"
    case sha512 = "rsa-sha2-512"

    /// Preference order: strongest first, which is also OpenSSH's order.
    public static let preferenceOrder: [NIOSSHRSASignatureAlgorithm] = [.sha512, .sha256]

    var utf8Name: String.UTF8View { rawValue.utf8 }


    init?<Bytes: Collection>(wireName: Bytes) where Bytes.Element == UInt8 {
        for candidate in NIOSSHRSASignatureAlgorithm.allCases
        where wireName.elementsEqual(candidate.rawValue.utf8) {
            self = candidate
            return
        }
        return nil
    }

    /// Signs `bytes` with this algorithm's digest.
    public func signature(for bytes: some DataProtocol, using key: _RSA.Signing.PrivateKey) throws -> Data {
        // RFC 8332 §3 specifies PKCS#1 v1.5, not PSS. `insecurePKCS1v1_5` names the
        // padding, not a weakness in this context.
        let signature: _RSA.Signing.RSASignature
        switch self {
        case .sha256:
            signature = try key.signature(for: SHA256.hash(data: bytes), padding: .insecurePKCS1v1_5)
        case .sha512:
            signature = try key.signature(for: SHA512.hash(data: bytes), padding: .insecurePKCS1v1_5)
        }
        return Data(signature.rawRepresentation)
    }

    public func isValidSignature(_ signature: Data, for bytes: some DataProtocol, using key: _RSA.Signing.PublicKey) -> Bool {
        let rsaSignature = _RSA.Signing.RSASignature(rawRepresentation: signature)
        switch self {
        case .sha256:
            return key.isValidSignature(rsaSignature, for: SHA256.hash(data: bytes), padding: .insecurePKCS1v1_5)
        case .sha512:
            return key.isValidSignature(rsaSignature, for: SHA512.hash(data: bytes), padding: .insecurePKCS1v1_5)
        }
    }
}

/// The wire identifier of an RSA *key blob*.
///
/// RFC 8332 §3: the blob is always `ssh-rsa`, whichever signature algorithm was
/// negotiated. Only the signature carries `rsa-sha2-256` or `rsa-sha2-512`. Conflating
/// the two is the classic implementation error in this feature, so the two names are kept
/// as separate concepts throughout.
enum NIOSSHRSAKeyBlob {
    static let prefix = "ssh-rsa".utf8
}

extension ByteBuffer {
    /// Writes an RSA public key blob: `mpint e`, `mpint n`.
    ///
    /// The exponent comes before the modulus, which is the reverse of most encodings and
    /// an easy thing to get backwards.
    mutating func writeRSAPublicKeyBody(_ key: _RSA.Signing.PublicKey) throws -> Int {
        let primitives = try key.getKeyPrimitives()
        var written = self.writePositiveMPInt(Array(primitives.publicExponent))
        written += self.writePositiveMPInt(Array(primitives.modulus))
        return written
    }

    /// Reads an RSA public key body, having already consumed the `ssh-rsa` identifier.
    mutating func readRSAPublicKeyBody() throws -> _RSA.Signing.PublicKey? {
        guard let eBytes = self.readSSHString(), let nBytes = self.readSSHString() else {
            return nil
        }
        let exponent = Self.strippingLeadingZeros(Data(eBytes.readableBytesView))
        let modulus = Self.strippingLeadingZeros(Data(nBytes.readableBytesView))
        do {
            return try _RSA.Signing.PublicKey(n: modulus, e: exponent)
        } catch {
            // A modulus below swift-crypto's floor, or otherwise unusable. Refusing is
            // right: a key we cannot verify with must not be treated as trusted.
            throw NIOSSHError.invalidSSHMessage(reason: "unusable RSA public key")
        }
    }

    /// An SSH `mpint` carries a sign byte that the raw magnitude must not keep.
    static func strippingLeadingZeros(_ data: Data) -> Data {
        var bytes = data
        while bytes.first == 0, bytes.count > 1 {
            bytes = bytes.dropFirst()
        }
        return bytes
    }
}
