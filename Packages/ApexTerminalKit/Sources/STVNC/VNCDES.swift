import CommonCrypto
import Foundation

/// The DES variant VNC Authentication uses (D-038).
///
/// The password is the key, truncated or zero-padded to eight bytes, with the bits of
/// every byte reversed — a historical quirk every VNC implementation reproduces — applied
/// in ECB to each half of the sixteen-byte challenge. It is 56-bit DES and offers no real
/// protection; the app says so (D-022). It is here because servers still require it.
///
/// The cipher itself is CommonCrypto's. An earlier version of this file carried a
/// hand-written DES — S-boxes, permutation tables and key schedule — under a comment
/// claiming no dependency exposed "this exact form". That was wrong: the bit reversal is
/// key *preparation*, not a different cipher, and `kCCAlgorithmDES` is exactly the block
/// cipher underneath it. Shipping a hand-written block cipher when the platform audits
/// one for you is a liability with no upside, and it made the export-compliance statement
/// in `docs/RELEASE.md` false.
enum VNCDES {
    /// The response a server expects: each half of the challenge encrypted under the
    /// password-derived key.
    static func encryptChallenge(_ challenge: [UInt8], password: String) -> [UInt8] {
        precondition(challenge.count == 16)
        var key = [UInt8](repeating: 0, count: 8)
        for (index, byte) in password.utf8.prefix(8).enumerated() {
            key[index] = reverseBits(byte)
        }
        return encryptBlock(Array(challenge[0 ..< 8]), key: key)
            + encryptBlock(Array(challenge[8 ..< 16]), key: key)
    }

    /// Every VNC server keys DES with the bits of each password byte in the opposite
    /// order. It is not cryptography, it is byte order, and it is why a client that skips
    /// it is refused by every server there is.
    static func reverseBits(_ byte: UInt8) -> UInt8 {
        var value = byte
        var result: UInt8 = 0
        for _ in 0 ..< 8 {
            result = (result << 1) | (value & 1)
            value >>= 1
        }
        return result
    }

    /// One DES block, ECB, no padding. Internal so a known-answer test can reach it: the
    /// challenge-response tests above it can only prove self-consistency, which a wrong
    /// cipher would satisfy too.
    static func encryptBlock(_ block: [UInt8], key: [UInt8]) -> [UInt8] {
        precondition(block.count == kCCBlockSizeDES && key.count == kCCKeySizeDES)
        var output = [UInt8](repeating: 0, count: kCCBlockSizeDES)
        var moved = 0
        let status = key.withUnsafeBufferPointer { keyBytes in
            block.withUnsafeBufferPointer { source in
                output.withUnsafeMutableBufferPointer { destination in
                    CCCrypt(
                        CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmDES), CCOptions(kCCOptionECBMode),
                        keyBytes.baseAddress, kCCKeySizeDES,
                        nil,
                        source.baseAddress, source.count,
                        destination.baseAddress, destination.count,
                        &moved
                    )
                }
            }
        }
        // A fixed-size ECB block with a fixed-size key cannot fail for any input, so a
        // failure here is a programming error rather than something to surface.
        precondition(status == kCCSuccess && moved == kCCBlockSizeDES, "DES block encryption failed")
        return output
    }
}
