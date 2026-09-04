import CBcryptPBKDF
import Foundation
import _CryptoExtras
import Crypto

/// The key-derivation step used when an OpenSSH private key file is passphrase
/// protected.
///
/// Modelled as a protocol so the parser can be exercised with a fast, deterministic
/// derivation in tests. The app always uses ``BcryptPBKDF``: a substituted derivation
/// would produce the wrong key and fail the check-integer test, so this cannot be used
/// to weaken security at runtime.
public protocol OpenSSHKeyDerivation: Sendable {
    func derive(passphrase: Data, salt: Data, rounds: Int, outputLength: Int) throws -> Data
}

/// OpenSSH's `bcrypt_pbkdf`, as vendored from OpenBSD.
///
/// There is no system API for this KDF, and reimplementing Blowfish in Swift would be
/// exactly the kind of hand-rolled cryptography this project avoids. The upstream C
/// implementation is used unmodified apart from replacing OpenSSH's build-system
/// headers; see `THIRD_PARTY_NOTICES.md`.
public struct BcryptPBKDF: OpenSSHKeyDerivation {
    public init() {}

    public func derive(passphrase: Data, salt: Data, rounds: Int, outputLength: Int) throws -> Data {
        guard rounds > 0, outputLength > 0, !salt.isEmpty else {
            throw SSHKeyParseError.malformed("invalid bcrypt KDF parameters")
        }
        var output = [UInt8](repeating: 0, count: outputLength)
        let status = passphrase.withUnsafeBytes { passBuffer -> Int32 in
            salt.withUnsafeBytes { saltBuffer -> Int32 in
                bcrypt_pbkdf(
                    passBuffer.baseAddress?.assumingMemoryBound(to: CChar.self),
                    passphrase.count,
                    saltBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    salt.count,
                    &output,
                    outputLength,
                    UInt32(rounds)
                )
            }
        }
        guard status == 0 else {
            throw SSHKeyParseError.malformed("bcrypt_pbkdf failed with status \(status)")
        }
        return Data(output)
    }
}

/// The symmetric ciphers OpenSSH uses to protect a private key file.
///
/// Only modes whose implementations come from the platform's audited crypto library
/// are supported; anything else is reported to the user with instructions for
/// re-encrypting the key rather than being silently mishandled.
enum CipherSpec: Sendable {
    case aes256CTR
    case aes256CBC
    case aes128CTR
    case aes128CBC

    static func forName(_ name: String) throws -> CipherSpec {
        switch name {
        case "aes256-ctr": .aes256CTR
        case "aes256-cbc": .aes256CBC
        case "aes128-ctr": .aes128CTR
        case "aes128-cbc": .aes128CBC
        default: throw SSHKeyParseError.unsupportedCipher(name)
        }
    }

    var keyLength: Int {
        switch self {
        case .aes256CTR, .aes256CBC: 32
        case .aes128CTR, .aes128CBC: 16
        }
    }

    var ivLength: Int { 16 }

    func decrypt(_ ciphertext: Data, key: Data, iv: Data) throws -> Data {
        let symmetricKey = SymmetricKey(data: key)
        switch self {
        case .aes256CTR, .aes128CTR:
            let counter = try AES._CTR.Nonce(nonceBytes: iv)
            return try AES._CTR.decrypt(ciphertext, using: symmetricKey, nonce: counter)
        case .aes256CBC, .aes128CBC:
            // The private section is always a whole number of cipher blocks, and
            // OpenSSH pads it itself, so no PKCS#7 unpadding is applied here.
            return try AES._CBC.decrypt(
                ciphertext,
                using: symmetricKey,
                iv: AES._CBC.IV(ivBytes: iv),
                noPadding: true
            )
        }
    }
}
