import Foundation
import STSSH

/// What a backup file contains, and the promise about what it does not (D-040).
///
/// Versioned from the first release, because a backup is the one file that outlives the
/// build that wrote it. A reader that meets a newer `formatVersion` says so rather than
/// guessing, and older files are migrated forward rather than rejected.
///
/// The default carries **no secret at all**: passwords and private keys stay in the
/// Keychain, and every record here is either public (a public key, a fingerprint) or a
/// preference. Secrets are opt-in, encrypted, and never in the same file as the plain
/// payload by accident — `payload` is present or `sealed` is, never both.
struct BackupDocument: Codable, Equatable {
    /// Bumped when the shape changes in a way a previous reader would misread. Adding an
    /// optional field does not need a bump; renaming or re-meaning one does.
    static let currentFormatVersion = 1

    var formatVersion: Int
    var exportedAt: Date
    /// The app that wrote it, so a support question can start from the right place.
    var appVersion: String
    /// Present when the file has no secrets in it.
    var payload: Payload?
    /// Present when the file has secrets, and then everything — including the plain
    /// records — is inside it. A backup with a password reveals nothing without it.
    var sealed: SealedPayload?

    /// Everything the app can put back without asking anyone for a secret.
    struct Payload: Codable, Equatable {
        var hosts: [Host] = []
        var screens: [ScreenConnection] = []
        var snippets: [Snippet] = []
        /// Public halves and fingerprints. The private halves are not here.
        var keys: [StoredKey] = []
        var knownHosts: [KnownHostEntry] = []
        var settings: Settings = Settings()
        /// Private keys, only ever present inside `sealed`.
        var privateKeys: [PrivateKeyBackup] = []
    }

    /// A private key, exported only on request and only inside an encrypted file.
    struct PrivateKeyBackup: Codable, Equatable {
        var keyID: UUID
        var openSSHPrivateKey: String
    }

    /// The preferences worth carrying to a new device. Deliberately not all of them:
    /// anything about this device's hardware, and anything the user would rather set
    /// again, is left behind.
    struct Settings: Codable, Equatable {
        var themeID: String?
        var lightThemeID: String?
        var followSystemAppearance: Bool?
        var fontSize: Double?
        var scrollbackLimit: Int?
        var customThemes: [TerminalTheme] = []
        var keyRowVisible: Bool?
        var cursorBlink: Bool?
        var bellEnabled: Bool?
        var automaticReconnect: Bool?
        var confirmMultilinePaste: Bool?
        var hideContentInAppSwitcher: Bool?
    }

    /// AES-GCM over the JSON payload, with the key derived from the user's passphrase.
    /// The parameters travel with the file so a future change to them can still read an
    /// old backup.
    struct SealedPayload: Codable, Equatable {
        var salt: Data
        var iterations: Int
        var combined: Data
    }

    var isEncrypted: Bool { sealed != nil }
}

/// What is wrong with a file, in words a person can act on.
enum BackupError: Error, Equatable {
    case notABackup
    case fromANewerVersion(Int)
    case needsPassword
    case wrongPassword
    case damaged(String)
}

extension BackupError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notABackup:
            String(localized: "That file is not an Apex Terminal backup.")
        case let .fromANewerVersion(version):
            String(localized: "This backup was written by a newer version of the app (format \(version)). Update Apex Terminal and try again.")
        case .needsPassword:
            String(localized: "This backup is encrypted. Enter the password it was exported with.")
        case .wrongPassword:
            String(localized: "That password does not open this backup.")
        case let .damaged(detail):
            String(localized: "This backup could not be read: \(detail)")
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .notABackup:
            String(localized: "Choose a file exported from Apex Terminal, ending in .apexbackup.")
        case .fromANewerVersion:
            String(localized: "A backup can always be read by the version that wrote it or a later one, never an earlier one.")
        case .needsPassword, .wrongPassword:
            String(localized: "The password is the one typed when the backup was exported. It is not stored anywhere and cannot be recovered.")
        case .damaged:
            String(localized: "Try exporting again from the device the backup came from.")
        }
    }
}
