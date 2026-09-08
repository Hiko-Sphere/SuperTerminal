import CommonCrypto
import CryptoKit
import Foundation

/// Sealing a backup with the user's own password (D-040).
///
/// PBKDF2-HMAC-SHA256 to turn a password into a key, then AES-GCM to seal — both from
/// Apple's frameworks, neither written here. The salt and the iteration count travel in
/// the file, so raising the count later still leaves old backups readable.
enum BackupCrypto {
    /// High enough to make a guessing attack expensive on the hardware of the day, low
    /// enough that unlocking a backup does not look like a hang. Stored per file, so this
    /// number can rise without stranding anything already written.
    static let defaultIterations = 320_000

    static func seal(_ plaintext: Data, password: String, iterations: Int = defaultIterations) throws -> BackupDocument.SealedPayload {
        var salt = Data(count: 32)
        let generated = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard generated == errSecSuccess else {
            throw BackupError.damaged("the system would not provide random bytes")
        }
        let key = try derive(password: password, salt: salt, iterations: iterations)
        let box = try AES.GCM.seal(plaintext, using: key)
        guard let combined = box.combined else {
            throw BackupError.damaged("the sealed box could not be written")
        }
        return BackupDocument.SealedPayload(salt: salt, iterations: iterations, combined: combined)
    }

    static func open(_ sealed: BackupDocument.SealedPayload, password: String) throws -> Data {
        let key = try derive(password: password, salt: sealed.salt, iterations: sealed.iterations)
        do {
            let box = try AES.GCM.SealedBox(combined: sealed.combined)
            return try AES.GCM.open(box, using: key)
        } catch {
            // AES-GCM authenticates, so a wrong password and a tampered file are the same
            // failure. Reporting it as the likely one is more useful than reporting both.
            throw BackupError.wrongPassword
        }
    }

    private static func derive(password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        guard iterations > 0, !salt.isEmpty else {
            throw BackupError.damaged("the backup's key parameters are missing")
        }
        var derived = Data(count: 32)
        let passwordBytes = Array(password.utf8)
        let status = derived.withUnsafeMutableBytes { output in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.isEmpty ? "" : password, passwordBytes.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    output.bindMemory(to: UInt8.self).baseAddress, 32
                )
            }
        }
        guard status == kCCSuccess else {
            throw BackupError.damaged("the password could not be turned into a key")
        }
        return SymmetricKey(data: derived)
    }
}
