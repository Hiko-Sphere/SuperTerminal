import CommonCrypto
import CryptoKit
import Foundation
import NIOCore

/// Apple's RFB security type 30, which is what macOS Screen Sharing offers (D-031).
///
/// A Mac with "Screen Sharing" or "Remote Management" turned on authenticates against a
/// macOS *account* — a user name and a password — rather than the single shared secret
/// classic VNC has. The exchange is Diffie-Hellman over a group the server picks, and the
/// credentials travel encrypted under the agreed key, so the password never crosses the
/// wire in the clear even on a connection that has no other encryption.
///
///   server → generator (2) ‖ key length (2) ‖ prime ‖ server public key
///   client → AES-128-ECB(MD5(shared secret), user name ‖ password) ‖ client public key
///
/// The 128-byte credentials block holds the user name at 0 and the password at 64, each
/// NUL-terminated, and the rest is random so that two logins with the same credentials do
/// not produce the same ciphertext.
enum VNCAppleAuthentication {
    /// What the server sends to open the exchange.
    struct Challenge {
        var generator: VNCBigInteger
        var prime: VNCBigInteger
        var serverPublicKey: VNCBigInteger
        var keyLength: Int
    }

    static let credentialsLength = 128
    private static let fieldLength = 64

    /// Parses the challenge, or returns nil when the whole of it has not arrived yet,
    /// leaving the buffer untouched in that case so the next read can try again.
    static func readChallenge(from buffer: inout ByteBuffer) throws -> Challenge? {
        guard let generator: UInt16 = buffer.getInteger(at: buffer.readerIndex),
              let keyLength: UInt16 = buffer.getInteger(at: buffer.readerIndex + 2)
        else { return nil }
        let length = Int(keyLength)
        // 4096 bits is far beyond any group a server offers, and a length this side does
        // not sanity-check is an allocation the other end chooses.
        guard length >= 8, length <= 512 else {
            throw VNCError.protocolError("the Mac offered a \(length * 8)-bit key")
        }
        guard buffer.readableBytes >= 4 + length * 2,
              let prime = buffer.getBytes(at: buffer.readerIndex + 4, length: length),
              let serverPublic = buffer.getBytes(at: buffer.readerIndex + 4 + length, length: length)
        else { return nil }
        buffer.moveReaderIndex(forwardBy: 4 + length * 2)
        // One extra limb so that doubling a number as wide as the prime cannot be lost.
        let limbs = (length + 7) / 8 + 1
        return Challenge(
            generator: VNCBigInteger(UInt64(generator), limbCount: limbs),
            prime: VNCBigInteger(bigEndian: prime, limbCount: limbs),
            serverPublicKey: VNCBigInteger(bigEndian: serverPublic, limbCount: limbs),
            keyLength: length
        )
    }

    /// The client's answer: the encrypted credentials followed by the client's public key.
    ///
    /// `privateKey` is a parameter so a test can replay a known exchange; every real call
    /// passes freshly generated random bytes.
    static func response(
        to challenge: Challenge,
        username: String,
        password: String,
        privateKey: [UInt8],
        padding: [UInt8]
    ) throws -> [UInt8] {
        let limbs = challenge.prime.limbs.count
        let secret = VNCBigInteger(bigEndian: privateKey, limbCount: limbs)
        let clientPublic = challenge.generator.power(secret, modulo: challenge.prime)
        let shared = challenge.serverPublicKey.power(secret, modulo: challenge.prime)
        let key = Data(Insecure.MD5.hash(data: Data(shared.bigEndianBytes(count: challenge.keyLength))))

        guard padding.count == credentialsLength else {
            throw VNCError.protocolError("credentials padding must be \(credentialsLength) bytes")
        }
        var credentials = padding
        write(username, into: &credentials, at: 0)
        write(password, into: &credentials, at: fieldLength)

        return try aes128ECBEncrypt(credentials, key: key) + clientPublic.bigEndianBytes(count: challenge.keyLength)
    }

    /// Copies a field in, NUL-terminated, leaving the random padding beyond it in place.
    /// A field too long for its 64 bytes is refused rather than silently truncated: a
    /// truncated password is a login that fails for a reason nobody could work out.
    private static func write(_ value: String, into block: inout [UInt8], at offset: Int) {
        let bytes = Array(value.utf8.prefix(fieldLength - 1))
        for index in 0 ..< bytes.count { block[offset + index] = bytes[index] }
        block[offset + bytes.count] = 0
    }

    static func aes128ECBEncrypt(_ plaintext: [UInt8], key: Data) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: plaintext.count)
        var moved = 0
        let status = key.withUnsafeBytes { keyBytes in
            plaintext.withUnsafeBufferPointer { source in
                output.withUnsafeMutableBufferPointer { destination in
                    CCCrypt(
                        CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                        keyBytes.baseAddress, kCCKeySizeAES128,
                        nil,
                        source.baseAddress, source.count,
                        destination.baseAddress, destination.count,
                        &moved
                    )
                }
            }
        }
        guard status == kCCSuccess, moved == plaintext.count else {
            throw VNCError.protocolError("the Mac's credentials could not be encrypted")
        }
        return output
    }

    /// Whether the credentials will fit the fixed fields the format allows.
    static func validate(username: String, password: String) throws {
        guard username.utf8.count < fieldLength, password.utf8.count < fieldLength else {
            throw VNCError.credentialsTooLong
        }
    }
}
