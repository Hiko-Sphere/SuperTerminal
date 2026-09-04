import Crypto
import Foundation
import NIOCore
import NIOSSH
import _CryptoExtras

/// Failures raised by a transport protection scheme implemented outside `NIOSSH`.
///
/// `NIOSSHError`'s constructors are internal, so a plugin cannot raise the library's own
/// errors. The protocol only requires that a failure throws, and these are deliberately
/// uniform: a peer must not be able to tell a bad MAC from a bad length by watching which
/// error comes back.
public struct SSHTransportProtectionError: Error, Equatable, Sendable {
    public enum Reason: String, Sendable {
        case invalidKeySize
        case malformedPacket
        case authenticationFailed
    }

    public let reason: Reason

    public static let invalidKeySize = SSHTransportProtectionError(reason: .invalidKeySize)
    public static let malformedPacket = SSHTransportProtectionError(reason: .malformedPacket)
    public static let authenticationFailed = SSHTransportProtectionError(reason: .authenticationFailed)
}

/// AES-CTR with encrypt-then-MAC, for servers that do not offer AES-GCM.
///
/// `swift-nio-ssh` ships only the two `@openssh.com` AES-GCM schemes. Every OpenSSH since
/// 6.2 offers those, so most servers are reachable without this — but hardening guides
/// routinely narrow `Ciphers` to the CTR family, and such a server is otherwise
/// unreachable no matter how modern it is.
///
/// This is a **plugin**, not a patch: `NIOSSHTransportProtection` is public and
/// `SSHClientConfiguration.transportProtectionSchemes` accepts additions, so the vendored
/// fork is untouched by it.
///
/// ## Why encrypt-then-MAC only
///
/// SSH's original construction computes the MAC over the *plaintext* and encrypts the
/// length field, so a receiver must decrypt before it can authenticate — the shape behind
/// a family of attacks on SSH's packet handling. `hmac-sha2-256-etm@openssh.com` moves
/// the MAC over the ciphertext and leaves the length in the clear, so a forged packet is
/// rejected before the cipher ever touches it. OpenSSH lists ETM variants first in its
/// defaults for the same reason.
///
/// The non-ETM `hmac-sha2-256` is deliberately not implemented. Adding it would let a
/// server negotiate the weaker construction, and every server that offers CTR with the
/// plain MAC also offers it with the ETM one.
///
/// No cryptography is implemented here. AES-CTR comes from `swift-crypto` and HMAC from
/// CryptoKit; what this type contributes is SSH's framing and counter bookkeeping.
public final class AES256CTRSHA256ETMTransportProtection: NIOSSHTransportProtection {
    public static let cipherName = "aes256-ctr"
    public static let macName: String? = "hmac-sha2-256-etm@openssh.com"
    public static let cipherBlockSize = 16
    public static let keySizes = ExpectedKeySizes(ivSize: 16, encryptionKeySize: 32, macKeySize: 32)

    public var macBytes: Int { 32 }

    /// ETM leaves the length field in the clear; that is the whole point of it.
    public var lengthEncrypted: Bool { false }

    private var outboundEncryptionKey: SymmetricKey
    private var inboundEncryptionKey: SymmetricKey
    private var outboundMACKey: SymmetricKey
    private var inboundMACKey: SymmetricKey
    /// CTR is a stream cipher, so the counter has to carry across packets — resetting it
    /// per packet would reuse keystream, which is fatal.
    private var outboundCounter: [UInt8]
    private var inboundCounter: [UInt8]

    public init(initialKeys: NIOSSHSessionKeys) throws {
        guard initialKeys.outboundEncryptionKey.bitCount == Self.keySizes.encryptionKeySize * 8,
              initialKeys.inboundEncryptionKey.bitCount == Self.keySizes.encryptionKeySize * 8,
              initialKeys.initialOutboundIV.count == Self.keySizes.ivSize,
              initialKeys.initialInboundIV.count == Self.keySizes.ivSize
        else {
            throw SSHTransportProtectionError.invalidKeySize
        }
        outboundEncryptionKey = initialKeys.outboundEncryptionKey
        inboundEncryptionKey = initialKeys.inboundEncryptionKey
        outboundMACKey = initialKeys.outboundMACKey
        inboundMACKey = initialKeys.inboundMACKey
        outboundCounter = initialKeys.initialOutboundIV
        inboundCounter = initialKeys.initialInboundIV
    }

    public func updateKeys(_ newKeys: NIOSSHSessionKeys) throws {
        guard newKeys.outboundEncryptionKey.bitCount == Self.keySizes.encryptionKeySize * 8,
              newKeys.inboundEncryptionKey.bitCount == Self.keySizes.encryptionKeySize * 8,
              newKeys.initialOutboundIV.count == Self.keySizes.ivSize,
              newKeys.initialInboundIV.count == Self.keySizes.ivSize
        else {
            throw SSHTransportProtectionError.invalidKeySize
        }
        outboundEncryptionKey = newKeys.outboundEncryptionKey
        inboundEncryptionKey = newKeys.inboundEncryptionKey
        outboundMACKey = newKeys.outboundMACKey
        inboundMACKey = newKeys.inboundMACKey
        // A rekey restarts the keystream from the new IV, which is what makes rekeying
        // meaningful.
        outboundCounter = newKeys.initialOutboundIV
        inboundCounter = newKeys.initialInboundIV
    }

    /// Nothing to do: the length is already plaintext under ETM.
    public func decryptFirstBlock(_: inout ByteBuffer) throws {}

    public func decryptAndVerifyRemainingPacket(
        _ source: inout ByteBuffer,
        sequenceNumber: UInt32
    ) throws -> ByteBuffer {
        let macBytes = self.macBytes
        guard source.readableBytes > 4 + macBytes else {
            throw SSHTransportProtectionError.malformedPacket
        }

        let ciphertextLength = source.readableBytes - 4 - macBytes
        guard ciphertextLength > 0, ciphertextLength % Self.cipherBlockSize == 0 else {
            throw SSHTransportProtectionError.malformedPacket
        }

        guard let lengthSlice = source.readSlice(length: 4),
              let ciphertextSlice = source.readSlice(length: ciphertextLength),
              let macSlice = source.readSlice(length: macBytes)
        else {
            throw SSHTransportProtectionError.malformedPacket
        }

        // Authenticate first. Under ETM the MAC covers the sequence number, the plaintext
        // length field and the ciphertext, so a forged packet is rejected before the
        // cipher is applied to it.
        var authenticated = Data()
        authenticated.reserveCapacity(4 + 4 + ciphertextLength)
        withUnsafeBytes(of: sequenceNumber.bigEndian) { authenticated.append(contentsOf: $0) }
        authenticated.append(contentsOf: lengthSlice.readableBytesView)
        authenticated.append(contentsOf: ciphertextSlice.readableBytesView)

        // `isValidAuthenticationCode` compares in constant time, which is the point:
        // a byte-by-byte comparison leaks how much of a forged MAC was correct.
        guard HMAC<SHA256>.isValidAuthenticationCode(
            Data(macSlice.readableBytesView),
            authenticating: authenticated,
            using: inboundMACKey
        ) else {
            throw SSHTransportProtectionError.authenticationFailed
        }

        var plaintext = try decryptInbound(Data(ciphertextSlice.readableBytesView))
        guard plaintext.count == ciphertextLength else {
            throw SSHTransportProtectionError.malformedPacket
        }

        // The plaintext begins with the padding length byte; strip it and the padding.
        let paddingLength = Int(plaintext.removeFirst())
        guard paddingLength >= 4, paddingLength <= plaintext.count else {
            throw SSHTransportProtectionError.malformedPacket
        }
        plaintext.removeLast(paddingLength)

        // `prependData` is fileprivate to NIOSSH, so the payload is returned in a buffer
        // of its own. The packet's bytes have already been consumed from `source`, which
        // is what the protocol requires.
        var payload = ByteBufferAllocator().buffer(capacity: plaintext.count)
        payload.writeContiguousBytes(plaintext)
        return payload
    }

    public func encryptPacket(_ destination: inout ByteBuffer, sequenceNumber: UInt32) throws {
        let lengthIndex = destination.readerIndex
        let bodyIndex = lengthIndex + 4
        let bodyLength = destination.readableBytes - 4
        guard bodyLength > 0, bodyLength % Self.cipherBlockSize == 0 else {
            throw SSHTransportProtectionError.malformedPacket
        }

        guard let lengthBytes = destination.getBytes(at: lengthIndex, length: 4),
              let body = destination.getBytes(at: bodyIndex, length: bodyLength)
        else {
            throw SSHTransportProtectionError.malformedPacket
        }

        let ciphertext = try encryptOutbound(Data(body))
        destination.setContiguousBytes(ciphertext, at: bodyIndex)

        var authenticated = Data()
        authenticated.reserveCapacity(4 + 4 + ciphertext.count)
        withUnsafeBytes(of: sequenceNumber.bigEndian) { authenticated.append(contentsOf: $0) }
        authenticated.append(contentsOf: lengthBytes)
        authenticated.append(ciphertext)

        let mac = HMAC<SHA256>.authenticationCode(for: authenticated, using: outboundMACKey)
        let written = destination.writeContiguousBytes(Data(mac))
        precondition(written == macBytes, "unexpected MAC length")
    }

    // MARK: - Counter-mode bookkeeping

    private func encryptOutbound(_ plaintext: Data) throws -> Data {
        let result = try AES._CTR.encrypt(
            plaintext,
            using: outboundEncryptionKey,
            nonce: try AES._CTR.Nonce(nonceBytes: outboundCounter)
        )
        outboundCounter = Self.advancing(outboundCounter, byBlocks: plaintext.count / Self.cipherBlockSize)
        return Data(result)
    }

    private func decryptInbound(_ ciphertext: Data) throws -> Data {
        let result = try AES._CTR.decrypt(
            ciphertext,
            using: inboundEncryptionKey,
            nonce: try AES._CTR.Nonce(nonceBytes: inboundCounter)
        )
        inboundCounter = Self.advancing(inboundCounter, byBlocks: ciphertext.count / Self.cipherBlockSize)
        return Data(result)
    }

    /// Adds `blocks` to a 128-bit big-endian counter, wrapping as the block cipher does.
    ///
    /// Exposed for testing: an off-by-one here produces a connection that works for
    /// exactly one packet and then desynchronises, which is a miserable thing to debug
    /// from the outside.
    public static func advancing(_ counter: [UInt8], byBlocks blocks: Int) -> [UInt8] {
        precondition(counter.count == 16, "an AES counter block is 16 bytes")
        guard blocks > 0 else { return counter }
        var result = counter
        var carry = UInt64(blocks)
        var index = 15
        while index >= 0, carry > 0 {
            let sum = UInt64(result[index]) + (carry & 0xFF)
            result[index] = UInt8(sum & 0xFF)
            carry = (carry >> 8) + (sum >> 8)
            index -= 1
        }
        return result
    }
}
