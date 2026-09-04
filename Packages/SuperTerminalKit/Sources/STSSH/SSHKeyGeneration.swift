import Crypto
import Foundation
import Security
import NIOSSH
import STCore

/// Key algorithms SuperTerminal can generate.
///
/// The list is short on purpose. Ed25519 is the right default for anyone who does not
/// have a specific reason to choose otherwise: small, fast, and with no parameter choices
/// to get wrong. ECDSA P-256 exists for environments whose policy still demands a NIST
/// curve. RSA is absent because the SSH layer cannot yet use it — see `DECISIONS.md`
/// D-007 — and offering to generate a key the app cannot authenticate with would be a
/// trap.
public enum SSHKeyAlgorithm: String, Sendable, CaseIterable, Identifiable {
    case ed25519
    case ecdsaP256

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .ed25519: "Ed25519"
        case .ecdsaP256: "ECDSA P-256"
        }
    }

    public var detail: String {
        switch self {
        case .ed25519: "Recommended. Short, fast, and supported by every current server."
        case .ecdsaP256: "For environments whose policy requires a NIST curve."
        }
    }

    public var sshName: String {
        switch self {
        case .ed25519: "ssh-ed25519"
        case .ecdsaP256: "ecdsa-sha2-nistp256"
        }
    }
}

/// Generates SSH key pairs and writes them in OpenSSH's format.
///
/// The private key is produced in the same `openssh-key-v1` container `ssh-keygen`
/// writes, so a key generated on the phone can be copied to a laptop, inspected with
/// `ssh-keygen -l`, or used by `ssh` directly. A key format only this app can read would
/// make the app a place keys go to be trapped.
public enum SSHKeyGenerator {
    /// A freshly generated key pair.
    public struct GeneratedKey: Sendable {
        /// The private key in `openssh-key-v1` PEM form, unencrypted.
        public let privateKeyPEM: String
        /// The public key as an `authorized_keys` line.
        public let publicKeyOpenSSH: String
        public let fingerprintSHA256: String
        public let algorithm: SSHKeyAlgorithm
    }

    public static func generate(algorithm: SSHKeyAlgorithm, comment: String) throws -> GeneratedKey {
        switch algorithm {
        case .ed25519:
            let privateKey = Curve25519.Signing.PrivateKey()
            let publicKeyBlob = ed25519PublicKeyBlob(privateKey.publicKey)
            let privateBlob = ed25519PrivateKeyBlob(privateKey, comment: comment)
            return try assemble(
                algorithm: algorithm,
                publicKeyBlob: publicKeyBlob,
                privateSection: privateBlob,
                comment: comment
            )
        case .ecdsaP256:
            let privateKey = P256.Signing.PrivateKey()
            let publicKeyBlob = p256PublicKeyBlob(privateKey.publicKey)
            let privateBlob = p256PrivateKeyBlob(privateKey, comment: comment)
            return try assemble(
                algorithm: algorithm,
                publicKeyBlob: publicKeyBlob,
                privateSection: privateBlob,
                comment: comment
            )
        }
    }

    // MARK: - Blob construction

    static func ed25519PublicKeyBlob(_ key: Curve25519.Signing.PublicKey) -> Data {
        var writer = SSHWireWriter()
        writer.writeString("ssh-ed25519")
        writer.writeString(key.rawRepresentation)
        return writer.data
    }

    static func ed25519PrivateKeyBlob(_ key: Curve25519.Signing.PrivateKey, comment: String) -> Data {
        var writer = SSHWireWriter()
        writer.writeString("ssh-ed25519")
        writer.writeString(key.publicKey.rawRepresentation)
        // OpenSSH stores the 32-byte seed followed by the 32-byte public key.
        writer.writeString(key.rawRepresentation + key.publicKey.rawRepresentation)
        writer.writeString(comment)
        return writer.data
    }

    static func p256PublicKeyBlob(_ key: P256.Signing.PublicKey) -> Data {
        var writer = SSHWireWriter()
        writer.writeString("ecdsa-sha2-nistp256")
        writer.writeString("nistp256")
        writer.writeString(key.x963Representation)
        return writer.data
    }

    static func p256PrivateKeyBlob(_ key: P256.Signing.PrivateKey, comment: String) -> Data {
        var writer = SSHWireWriter()
        writer.writeString("ecdsa-sha2-nistp256")
        writer.writeString("nistp256")
        writer.writeString(key.publicKey.x963Representation)
        // The private scalar is an mpint: a leading zero byte is required when the high
        // bit is set, or the value reads as negative.
        writer.writeString(mpint(key.rawRepresentation))
        writer.writeString(comment)
        return writer.data
    }

    /// Encodes a magnitude as an SSH `mpint`.
    static func mpint(_ magnitude: Data) -> Data {
        var bytes = magnitude
        while bytes.first == 0, bytes.count > 1 { bytes = bytes.dropFirst() }
        if let first = bytes.first, first & 0x80 != 0 {
            return Data([0]) + bytes
        }
        return bytes
    }

    /// Wraps the blobs in the `openssh-key-v1` container.
    private static func assemble(
        algorithm: SSHKeyAlgorithm,
        publicKeyBlob: Data,
        privateSection: Data,
        comment: String
    ) throws -> GeneratedKey {
        // The check integers must match on decryption. For an unencrypted key any value
        // works, but it is still random so that two keys generated in the same second do
        // not produce byte-identical containers.
        var checkBytes = Data(count: 4)
        checkBytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = SecRandomCopyBytes(kSecRandomDefault, 4, base)
        }
        let check = checkBytes.withUnsafeBytes { $0.load(as: UInt32.self) }

        var privateWriter = SSHWireWriter()
        privateWriter.writeUInt32(check)
        privateWriter.writeUInt32(check)
        privateWriter.writeRaw(privateSection)
        // Padded to the cipher's block size with 1, 2, 3 … even for "none", where the
        // block size is 8.
        var padded = privateWriter.data
        var padding: UInt8 = 1
        while padded.count % 8 != 0 {
            padded.append(padding)
            padding += 1
        }

        var container = Data("openssh-key-v1\0".utf8)
        var writer = SSHWireWriter()
        writer.writeString("none")      // cipher
        writer.writeString("none")      // kdf
        writer.writeString(Data())      // kdf options
        writer.writeUInt32(1)           // key count
        writer.writeString(publicKeyBlob)
        writer.writeString(padded)
        container.append(writer.data)

        let base64 = container.base64EncodedString()
        var pem = "-----BEGIN OPENSSH PRIVATE KEY-----\n"
        var index = base64.startIndex
        while index < base64.endIndex {
            let end = base64.index(index, offsetBy: 70, limitedBy: base64.endIndex) ?? base64.endIndex
            pem += base64[index ..< end] + "\n"
            index = end
        }
        pem += "-----END OPENSSH PRIVATE KEY-----\n"

        let hostKey = SSHHostKey(algorithm: algorithm.sshName, blob: publicKeyBlob)
        let publicLine = "\(algorithm.sshName) \(publicKeyBlob.base64EncodedString()) \(comment)"

        // Parse what was just written before handing it back. A key that this app cannot
        // read is not a key, and finding that out at generation time is far better than
        // at the first connection attempt.
        let reparsed = try OpenSSHPrivateKeyParser.parse(pem: pem)
        guard reparsed.publicKey == hostKey else {
            throw STError(
                category: .internalError,
                message: "The generated key did not round-trip; it has not been saved.",
                underlyingDescription: "public key mismatch after re-parsing"
            )
        }

        return GeneratedKey(
            privateKeyPEM: pem,
            publicKeyOpenSSH: publicLine,
            fingerprintSHA256: hostKey.fingerprintSHA256,
            algorithm: algorithm
        )
    }
}
