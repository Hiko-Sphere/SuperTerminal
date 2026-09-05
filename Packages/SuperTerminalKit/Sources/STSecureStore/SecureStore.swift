import Foundation
import STCore

/// How aggressively an item is protected at rest.
///
/// The mapping to Keychain accessibility classes is deliberate and documented in
/// `SECURITY.md`: nothing SuperTerminal stores is available before first unlock, and
/// nothing is eligible for iCloud Keychain or an unencrypted device backup.
public enum SecureStoreProtection: Sendable, Equatable {
    /// Readable while the device is unlocked, and only on this device.
    /// Used for host configuration secrets such as saved passwords.
    case whenUnlockedThisDeviceOnly
    /// Readable after the first unlock following boot, and only on this device.
    /// Used for material a reconnect may need while the app is in the background.
    case afterFirstUnlockThisDeviceOnly
    /// Requires a successful biometric or passcode check at every read, and is
    /// invalidated if the device's biometric enrolment changes.
    case biometricThisDeviceOnly
    /// Readable while the device is unlocked, and synchronised through iCloud Keychain —
    /// Apple's end-to-end-encrypted keychain sync — to the user's other devices.
    ///
    /// Opt-in per item, never a default. Two rules from Apple's `SecItem.h`, stated
    /// there as caveats and enforced here: a synchronisable item may not use a
    /// `…ThisDeviceOnly` accessibility class, and it cannot carry access-control based
    /// protection — so an item that requires Face ID or Touch ID can never be
    /// synchronised. That is why the app refuses the combination rather than silently
    /// dropping the biometric requirement to make sync work.
    case whenUnlockedSynchronizable
}

/// A single stored secret's address.
public struct SecureStoreKey: Sendable, Hashable {
    /// Groups related items, e.g. `cloudflare.token` or `ssh.privatekey`.
    public let service: String
    /// Identifies the item within its service.
    public let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }
}

public enum SecureStoreError: Error, Sendable, Equatable {
    case itemNotFound
    case duplicateItem
    case authenticationFailed
    case userCancelled
    case interactionNotAllowed
    case unhandled(status: Int32)

    public var stError: STError {
        switch self {
        case .itemNotFound:
            STError(category: .credential, message: "The stored credential could not be found.")
        case .duplicateItem:
            STError(category: .credential, message: "A credential with that name already exists.")
        case .authenticationFailed:
            STError(
                category: .credential,
                message: "Could not unlock the stored credential.",
                recoverySuggestion: "Try again and complete the Face ID, Touch ID or passcode prompt."
            )
        case .userCancelled:
            STError(category: .cancelled, message: "Unlocking the credential was cancelled.")
        case .interactionNotAllowed:
            STError(
                category: .credential,
                message: "The credential is unavailable while the device is locked.",
                recoverySuggestion: "Unlock the device and try again."
            )
        case let .unhandled(status):
            STError(
                category: .credential,
                message: "The secure store returned an unexpected error.",
                underlyingDescription: "OSStatus \(status)"
            )
        }
    }
}

/// Storage for every secret the app holds.
///
/// The protocol exists so that pure logic — token lifecycle, key management — can be
/// unit tested without a Keychain, while the shipping app always uses
/// ``KeychainSecureStore``. No in-memory implementation is ever wired into a release
/// build; see `SECURITY.md`.
public protocol SecureStore: Sendable {
    func set(_ data: Data, for key: SecureStoreKey, protection: SecureStoreProtection, prompt: String?) throws
    func get(_ key: SecureStoreKey, prompt: String?) throws -> Data
    func remove(_ key: SecureStoreKey) throws
    /// Lists the accounts stored under `service`. Never returns secret material.
    func accounts(inService service: String) throws -> [String]
    /// Removes every item under `service`. Used by "delete all data".
    func removeAll(inService service: String) throws
}

public extension SecureStore {
    func set(_ data: Data, for key: SecureStoreKey, protection: SecureStoreProtection) throws {
        try set(data, for: key, protection: protection, prompt: nil)
    }

    func get(_ key: SecureStoreKey) throws -> Data {
        try get(key, prompt: nil)
    }

    func getIfPresent(_ key: SecureStoreKey, prompt: String? = nil) throws -> Data? {
        do {
            return try get(key, prompt: prompt)
        } catch SecureStoreError.itemNotFound {
            return nil
        }
    }
}
