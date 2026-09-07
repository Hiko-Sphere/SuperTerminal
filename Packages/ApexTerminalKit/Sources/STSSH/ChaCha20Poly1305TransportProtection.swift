import Clibsodium
import Crypto
import Foundation
import NIOCore
import NIOSSH

/// `chacha20-poly1305@openssh.com`, OpenSSH's own AEAD construction.
///
/// This is **not** the RFC 8439 `ChaCha20-Poly1305` that `swift-crypto`'s `ChaChaPoly`
/// implements, and the sealed-box API cannot express it: OpenSSH runs two ChaCha20
/// instances under two keys, encrypts the packet length on its own so the receiver can
/// learn how much to read before authenticating anything, and derives the one-time
/// Poly1305 key from the first block of keystream. So the stream cipher and the
/// authenticator are used separately, from libsodium, which the app already ships for
/// the Cloudflare login flow. No cryptographic primitive is implemented here; what this
/// type contributes is OpenSSH's framing, and the discipline of authenticating before
/// decrypting.
///
/// ## The construction, from OpenSSH's `PROTOCOL.chacha20poly1305`
///
/// The key exchange yields 64 bytes: the first 32 are `K_2` (payload), the second 32 are
/// `K_1` (length). The nonce for both is the packet sequence number as 8 big-endian bytes.
///
///   * `C_len     = ChaCha20(K_1, nonce, counter 0) ⊕ length`   — 4 bytes
///   * `polyKey   = ChaCha20(K_2, nonce, counter 0)[0 ..< 32]`  — keystream, first block
///   * `C_payload = ChaCha20(K_2, nonce, counter 1) ⊕ payload`
///   * `tag       = Poly1305(polyKey, C_len ‖ C_payload)`      — 16 bytes
///
/// Reading a packet: decrypt the length, learn the size, wait for the rest, **verify the
/// tag**, and only then decrypt the payload. A forged packet is rejected before the cipher
/// touches its body.
///
/// ## Why this needed a change to the vendored key exchange
///
/// 64 bytes of key with a 32-byte SHA-256 digest is the case RFC 4253 § 7.2's key extension
/// exists for, and upstream `swift-nio-ssh` never implemented it because no bundled cipher
/// needed it. That extension is now part of the vendored patch; this type is the reason.
public final class ChaCha20Poly1305TransportProtection: NIOSSHTransportProtection {
    public static let cipherName = "chacha20-poly1305@openssh.com"
    /// An AEAD: the MAC negotiation is ignored, as it is for the AES-GCM schemes.
    public static let macName: String? = nil
    /// OpenSSH pads chacha20-poly1305 packets to 8 bytes.
    public static let cipherBlockSize = 8
    /// Two 256-bit keys; no IV (the nonce is the sequence number) and no MAC key (the
    /// one-time key is derived from keystream).
    public static let keySizes = ExpectedKeySizes(ivSize: 0, encryptionKeySize: 64, macKeySize: 0)

    public var macBytes: Int { 16 }
    /// The length *is* encrypted, but under a separate cipher instance, so for padding it
    /// is treated like associated data: the padded region excludes it. This is what
    /// OpenSSH does (`aadlen = 4`), and it is what `lengthEncrypted = false` selects in the
    /// serializer. `decryptFirstBlock` still decrypts it.
    public var lengthEncrypted: Bool { false }

    private static let keyBytes = 32
    private static let nonceBytes = 8
    private static let tagBytes = 16

    /// `sodium_init` is idempotent and the library is already initialised by the Cloudflare
    /// code path when that runs first — but nothing guarantees ordering, so it is called
    /// here too. Once per process is enough; a negative result means libsodium is unusable.
    private static let sodiumReady: Bool = sodium_init() >= 0

    private var outboundPayloadKey: [UInt8]
    private var outboundLengthKey: [UInt8]
    private var inboundPayloadKey: [UInt8]
    private var inboundLengthKey: [UInt8]

    public init(initialKeys: NIOSSHSessionKeys) throws {
        guard Self.sodiumReady else { throw SSHTransportProtectionError.invalidKeySize }
        (outboundPayloadKey, outboundLengthKey) = try Self.split(initialKeys.outboundEncryptionKey)
        (inboundPayloadKey, inboundLengthKey) = try Self.split(initialKeys.inboundEncryptionKey)
    }

    public func updateKeys(_ newKeys: NIOSSHSessionKeys) throws {
        // Nothing else to reset: the nonce is the sequence number, which the connection
        // owns, so a rekey is complete once the keys are replaced.
        (outboundPayloadKey, outboundLengthKey) = try Self.split(newKeys.outboundEncryptionKey)
        (inboundPayloadKey, inboundLengthKey) = try Self.split(newKeys.inboundEncryptionKey)
    }

    /// The first 32 bytes are the payload key, the second 32 the length key — in that
    /// order, which is the one thing about this cipher that is easy to get backwards.
    private static func split(_ key: SymmetricKey) throws -> (payload: [UInt8], length: [UInt8]) {
        guard key.bitCount == keySizes.encryptionKeySize * 8 else {
            throw SSHTransportProtectionError.invalidKeySize
        }
        let bytes = key.withUnsafeBytes { Array($0) }
        return (Array(bytes[0 ..< keyBytes]), Array(bytes[keyBytes ..< 2 * keyBytes]))
    }

    // MARK: - Primitives

    private static func nonce(for sequenceNumber: UInt32) -> [UInt8] {
        // 8 bytes, big-endian, of the 32-bit sequence number zero-extended to 64.
        withUnsafeBytes(of: UInt64(sequenceNumber).bigEndian) { Array($0) }
    }

    /// ChaCha20 keystream XOR, starting at block `counter`. Symmetric, so it both encrypts
    /// and decrypts.
    private static func chacha20(_ input: [UInt8], key: [UInt8], nonce: [UInt8], counter: UInt64) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: input.count)
        guard !input.isEmpty else { return output }
        precondition(key.count == keyBytes && nonce.count == nonceBytes, "ChaCha20 key or nonce of the wrong size")
        // The unwraps are sound: `input` is non-empty (guarded above), `output` matches it,
        // and the key and nonce sizes were just checked — an empty buffer is the only way
        // `baseAddress` is nil.
        let status = output.withUnsafeMutableBufferPointer { out in
            input.withUnsafeBufferPointer { inp in
                key.withUnsafeBufferPointer { k in
                    nonce.withUnsafeBufferPointer { n in
                        crypto_stream_chacha20_xor_ic(
                            out.baseAddress!, inp.baseAddress!, UInt64(input.count),
                            n.baseAddress!, counter, k.baseAddress!
                        )
                    }
                }
            }
        }
        precondition(status == 0, "libsodium refused a ChaCha20 operation with valid sizes")
        return output
    }

    /// The one-time Poly1305 key: the first 32 bytes of keystream at counter 0.
    private static func polyKey(key: [UInt8], nonce: [UInt8]) -> [UInt8] {
        chacha20([UInt8](repeating: 0, count: keyBytes), key: key, nonce: nonce, counter: 0)
    }

    private static func poly1305(_ message: [UInt8], key: [UInt8]) -> [UInt8] {
        var tag = [UInt8](repeating: 0, count: tagBytes)
        precondition(!message.isEmpty && key.count == keyBytes, "Poly1305 over an empty message or a short key")
        // Sound for the same reason as above: none of these buffers can be empty here.
        let status = tag.withUnsafeMutableBufferPointer { out in
            message.withUnsafeBufferPointer { msg in
                key.withUnsafeBufferPointer { k in
                    crypto_onetimeauth_poly1305(out.baseAddress!, msg.baseAddress!, UInt64(message.count), k.baseAddress!)
                }
            }
        }
        precondition(status == 0, "libsodium refused a Poly1305 operation with valid sizes")
        return tag
    }

    // MARK: - Inbound

    /// Decrypts the 4-byte length in place, so the connection can learn the packet size.
    ///
    /// Only the length is decrypted — not the 8-byte "block" the connection waited for.
    /// Bytes 4 to 7 belong to the payload, which runs under the other key at counter 1 and
    /// is not touched until the tag has been verified.
    public func decryptFirstBlock(_ source: inout ByteBuffer, sequenceNumber: UInt32) throws {
        guard let encryptedLength = source.getBytes(at: source.readerIndex, length: 4) else {
            throw SSHTransportProtectionError.malformedPacket
        }
        let nonce = Self.nonce(for: sequenceNumber)
        let plaintextLength = Self.chacha20(encryptedLength, key: inboundLengthKey, nonce: nonce, counter: 0)
        source.setBytes(plaintextLength, at: source.readerIndex)
    }

    public func decryptAndVerifyRemainingPacket(
        _ source: inout ByteBuffer,
        sequenceNumber: UInt32
    ) throws -> ByteBuffer {
        let nonce = Self.nonce(for: sequenceNumber)
        guard source.readableBytes > 4 + Self.tagBytes,
              let plaintextLength = source.getBytes(at: source.readerIndex, length: 4)
        else { throw SSHTransportProtectionError.malformedPacket }

        // The buffer now holds the *plaintext* length, written by `decryptFirstBlock`. The
        // tag was computed over the ciphertext, and ChaCha20 is an XOR, so encrypting the
        // plaintext again under the same key, nonce and counter recovers it exactly. No
        // state has to survive between the two calls.
        let encryptedLength = Self.chacha20(plaintextLength, key: inboundLengthKey, nonce: nonce, counter: 0)
        let length = Int(UInt32(bigEndian: plaintextLength.withUnsafeBytes { $0.load(as: UInt32.self) }))
        guard length > 0, 4 + length + Self.tagBytes <= source.readableBytes else {
            throw SSHTransportProtectionError.malformedPacket
        }

        source.moveReaderIndex(forwardBy: 4)
        guard let ciphertext = source.readBytes(length: length),
              let tag = source.readBytes(length: Self.tagBytes)
        else { throw SSHTransportProtectionError.malformedPacket }

        // Authenticate before decrypting anything of the body. The tag covers the
        // encrypted length and the encrypted payload, in that order.
        let polyKey = Self.polyKey(key: inboundPayloadKey, nonce: nonce)
        let expected = Self.poly1305(encryptedLength + ciphertext, key: polyKey)
        // Both are exactly 16 bytes — `expected` by construction, `tag` by the read above.
        let verdict = expected.withUnsafeBufferPointer { e in
            tag.withUnsafeBufferPointer { t in crypto_verify_16(e.baseAddress!, t.baseAddress!) }
        }
        // `crypto_verify_16` is constant-time; a byte-wise `==` would leak how much of a
        // forged tag was right.
        guard verdict == 0 else { throw SSHTransportProtectionError.authenticationFailed }

        var plaintext = Self.chacha20(ciphertext, key: inboundPayloadKey, nonce: nonce, counter: 1)

        // Strip padding: the first byte says how much, and RFC 4253 requires at least 4.
        guard let paddingLength = plaintext.first.map(Int.init),
              paddingLength >= 4, 1 + paddingLength <= plaintext.count
        else { throw SSHTransportProtectionError.malformedPacket }
        plaintext.removeLast(paddingLength)
        plaintext.removeFirst()

        var body = ByteBufferAllocator().buffer(capacity: plaintext.count)
        body.writeBytes(plaintext)
        return body
    }

    // MARK: - Outbound

    /// `destination` holds `length ‖ padding_length ‖ payload ‖ padding`; on return it
    /// holds `C_len ‖ C_payload ‖ tag`.
    public func encryptPacket(_ destination: inout ByteBuffer, sequenceNumber: UInt32) throws {
        let start = destination.readerIndex
        guard destination.readableBytes > 4,
              let lengthBytes = destination.getBytes(at: start, length: 4),
              let payload = destination.getBytes(at: start + 4, length: destination.readableBytes - 4)
        else { throw SSHTransportProtectionError.malformedPacket }

        let nonce = Self.nonce(for: sequenceNumber)
        let encryptedLength = Self.chacha20(lengthBytes, key: outboundLengthKey, nonce: nonce, counter: 0)
        let ciphertext = Self.chacha20(payload, key: outboundPayloadKey, nonce: nonce, counter: 1)
        let polyKey = Self.polyKey(key: outboundPayloadKey, nonce: nonce)
        let tag = Self.poly1305(encryptedLength + ciphertext, key: polyKey)

        destination.setBytes(encryptedLength, at: start)
        destination.setBytes(ciphertext, at: start + 4)
        let written = destination.writeBytes(tag)
        precondition(written == macBytes, "unexpected short tag")
    }
}
