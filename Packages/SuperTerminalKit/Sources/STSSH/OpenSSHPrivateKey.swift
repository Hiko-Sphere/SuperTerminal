import Crypto
import Foundation
import NIOSSH
import STCore

/// A private key SuperTerminal can authenticate with, together with the metadata
/// needed to show it in the UI.
public struct SSHPrivateKeyMaterial: Sendable {
    public let key: NIOSSHPrivateKey
    public let algorithm: String
    public let comment: String?
    /// The matching public key, so a key can be shown and exported without unlocking
    /// the private half again.
    public let publicKey: SSHHostKey

    init(key: NIOSSHPrivateKey, algorithm: String, comment: String?, publicKey: SSHHostKey) {
        self.key = key
        self.algorithm = algorithm
        self.comment = comment
        self.publicKey = publicKey
    }
}

public enum SSHKeyParseError: Error, Sendable, Equatable {
    case notAnOpenSSHPrivateKey
    case malformed(String)
    case passphraseRequired
    case incorrectPassphrase
    case unsupportedCipher(String)
    case unsupportedKDF(String)
    case unsupportedKeyType(String)

    public var stError: STError {
        switch self {
        case .notAnOpenSSHPrivateKey:
            STError(
                category: .credential,
                message: "That file is not an OpenSSH private key.",
                recoverySuggestion: "Export the key with `ssh-keygen -p -f <key>` or generate a new one in SuperTerminal."
            )
        case let .malformed(detail):
            STError(
                category: .credential,
                message: "The private key file is damaged or incomplete.",
                underlyingDescription: detail
            )
        case .passphraseRequired:
            STError(
                category: .credential,
                message: "This private key is protected by a passphrase.",
                recoverySuggestion: "Enter the key's passphrase to import it."
            )
        case .incorrectPassphrase:
            STError(
                category: .credential,
                message: "That passphrase does not unlock this key.",
                recoverySuggestion: "Check the passphrase and try again."
            )
        case let .unsupportedCipher(name):
            STError(
                category: .credential,
                message: "This key uses an encryption method SuperTerminal cannot read (\(name)).",
                recoverySuggestion: "Re-encrypt the key with `ssh-keygen -p -Z aes256-ctr -f <key>`, or import it without a passphrase."
            )
        case let .unsupportedKDF(name):
            STError(
                category: .credential,
                message: "This key uses an unsupported key-derivation function (\(name)).",
                recoverySuggestion: "Re-encrypt the key with a current version of `ssh-keygen`."
            )
        case let .unsupportedKeyType(type):
            STError(
                category: .credential,
                message: "SuperTerminal does not support \(type) keys yet.",
                recoverySuggestion: "Use an Ed25519 or ECDSA P-256 key. See the compatibility matrix in the app's documentation."
            )
        }
    }
}

/// Parses the `-----BEGIN OPENSSH PRIVATE KEY-----` container that `ssh-keygen` has
/// produced by default since OpenSSH 7.8.
///
/// The format is documented in OpenSSH's `PROTOCOL.key`. This parser implements it
/// directly rather than shelling out or linking OpenSSH, and it treats every field as
/// untrusted input.
public enum OpenSSHPrivateKeyParser {
    static let beginMarker = "-----BEGIN OPENSSH PRIVATE KEY-----"
    static let endMarker = "-----END OPENSSH PRIVATE KEY-----"
    static let magic = "openssh-key-v1\0"

    /// Describes a key file without unlocking it, so the UI can ask for a passphrase
    /// only when one is actually needed.
    public struct Inspection: Sendable, Equatable {
        public let isEncrypted: Bool
        public let cipher: String
        public let kdf: String
        public let publicKeyAlgorithm: String
    }

    public static func inspect(pem: String) throws -> Inspection {
        let container = try decodeContainer(pem: pem)
        return Inspection(
            isEncrypted: container.cipherName != "none",
            cipher: container.cipherName,
            kdf: container.kdfName,
            publicKeyAlgorithm: container.publicKeyAlgorithm
        )
    }

    /// Parses and unlocks a key.
    ///
    /// - Parameter passphrase: required when the file is encrypted; ignored otherwise.
    public static func parse(
        pem: String,
        passphrase: String? = nil,
        kdf: any OpenSSHKeyDerivation = BcryptPBKDF()
    ) throws -> SSHPrivateKeyMaterial {
        let container = try decodeContainer(pem: pem)

        let plaintext: Data
        if container.cipherName == "none" {
            plaintext = container.encryptedPrivateSection
        } else {
            guard let passphrase, !passphrase.isEmpty else { throw SSHKeyParseError.passphraseRequired }
            plaintext = try decrypt(container: container, passphrase: passphrase, kdf: kdf)
        }

        var reader = SSHWireReader(plaintext)
        guard let check1 = reader.readUInt32(), let check2 = reader.readUInt32() else {
            throw SSHKeyParseError.malformed("private section is truncated")
        }
        guard check1 == check2 else {
            // The check integers are OpenSSH's decryption oracle: they only match when
            // the passphrase was right.
            throw container.cipherName == "none"
                ? SSHKeyParseError.malformed("check integers do not match")
                : SSHKeyParseError.incorrectPassphrase
        }

        guard let keyType = reader.readStringUTF8() else {
            throw SSHKeyParseError.malformed("private key type is missing")
        }

        switch keyType {
        case "ssh-ed25519":
            guard let publicKeyBytes = reader.readString(), publicKeyBytes.count == 32,
                  let privateBlob = reader.readString(), privateBlob.count == 64
            else {
                throw SSHKeyParseError.malformed("ed25519 key fields are malformed")
            }
            // OpenSSH stores seed||public; Curve25519 signing keys are built from the seed.
            let seed = privateBlob.prefix(32)
            guard privateBlob.suffix(32) == publicKeyBytes else {
                throw SSHKeyParseError.malformed("ed25519 public key does not match the private key")
            }
            let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
            let comment = reader.readStringUTF8()
            let nioKey = NIOSSHPrivateKey(ed25519Key: signingKey)
            return SSHPrivateKeyMaterial(
                key: nioKey,
                algorithm: keyType,
                comment: comment.flatMap { $0.isEmpty ? nil : $0 },
                publicKey: try SSHHostKey(nioKey.publicKey)
            )

        case "ecdsa-sha2-nistp256":
            guard let curve = reader.readStringUTF8(), curve == "nistp256",
                  reader.readString() != nil,
                  let scalar = reader.readMPInt()
            else {
                throw SSHKeyParseError.malformed("ECDSA P-256 key fields are malformed")
            }
            // P-256 private scalars are 32 bytes; OpenSSH strips leading zeros.
            var raw = scalar
            while raw.count < 32 { raw.insert(0, at: raw.startIndex) }
            guard raw.count == 32 else {
                throw SSHKeyParseError.malformed("ECDSA P-256 private scalar has the wrong length")
            }
            let signingKey = try P256.Signing.PrivateKey(rawRepresentation: raw)
            let comment = reader.readStringUTF8()
            let nioKey = NIOSSHPrivateKey(p256Key: signingKey)
            return SSHPrivateKeyMaterial(
                key: nioKey,
                algorithm: keyType,
                comment: comment.flatMap { $0.isEmpty ? nil : $0 },
                publicKey: try SSHHostKey(nioKey.publicKey)
            )

        default:
            throw SSHKeyParseError.unsupportedKeyType(keyType)
        }
    }

    // MARK: - Container

    struct Container {
        let cipherName: String
        let kdfName: String
        let kdfOptions: Data
        let publicKeyAlgorithm: String
        let encryptedPrivateSection: Data
    }

    static func decodeContainer(pem: String) throws -> Container {
        let lines = pem.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let begin = lines.firstIndex(of: beginMarker),
              let end = lines.firstIndex(of: endMarker),
              begin < end
        else {
            throw SSHKeyParseError.notAnOpenSSHPrivateKey
        }
        let body = lines[(begin + 1) ..< end].joined()
        guard let raw = Data(base64Encoded: body, options: [.ignoreUnknownCharacters]) else {
            throw SSHKeyParseError.malformed("key body is not valid base64")
        }
        guard raw.count > magic.utf8.count, raw.prefix(magic.utf8.count) == Data(magic.utf8) else {
            throw SSHKeyParseError.notAnOpenSSHPrivateKey
        }

        var reader = SSHWireReader(raw.dropFirst(magic.utf8.count))
        guard let cipherName = reader.readStringUTF8(),
              let kdfName = reader.readStringUTF8(),
              let kdfOptions = reader.readString(),
              let keyCount = reader.readUInt32()
        else {
            throw SSHKeyParseError.malformed("key header is truncated")
        }
        guard keyCount == 1 else {
            throw SSHKeyParseError.malformed("multi-key files are not supported (found \(keyCount) keys)")
        }
        guard let publicKeyBlob = reader.readString(),
              let privateSection = reader.readString()
        else {
            throw SSHKeyParseError.malformed("key body is truncated")
        }

        var publicReader = SSHWireReader(publicKeyBlob)
        guard let publicKeyAlgorithm = publicReader.readStringUTF8() else {
            throw SSHKeyParseError.malformed("public key blob is malformed")
        }

        return Container(
            cipherName: cipherName,
            kdfName: kdfName,
            kdfOptions: kdfOptions,
            publicKeyAlgorithm: publicKeyAlgorithm,
            encryptedPrivateSection: privateSection
        )
    }

    static func decrypt(container: Container, passphrase: String, kdf: any OpenSSHKeyDerivation) throws -> Data {
        guard container.kdfName == "bcrypt" else {
            throw SSHKeyParseError.unsupportedKDF(container.kdfName)
        }
        var options = SSHWireReader(container.kdfOptions)
        guard let salt = options.readString(), let rounds = options.readUInt32(), rounds > 0 else {
            throw SSHKeyParseError.malformed("bcrypt KDF options are malformed")
        }

        let spec = try CipherSpec.forName(container.cipherName)
        let derived = try kdf.derive(
            passphrase: Data(passphrase.utf8),
            salt: salt,
            rounds: Int(rounds),
            outputLength: spec.keyLength + spec.ivLength
        )
        let key = derived.prefix(spec.keyLength)
        let iv = derived.suffix(spec.ivLength)
        return try spec.decrypt(container.encryptedPrivateSection, key: Data(key), iv: Data(iv))
    }
}
