import Foundation
import STCloudflare
import STCore
import STSSH
import STSecureStore

/// The one place that reads and writes secret material.
///
/// Concentrating it here means a security review has a single file to read, and the
/// Keychain protection class for each kind of secret is decided once rather than at
/// every call site.
struct CredentialVault: Sendable {
    /// Keychain services. Separate services rather than one, so "forget all Cloudflare
    /// sessions" and "delete all keys" are each a single scoped delete.
    enum Service {
        static let privateKeys = "dev.superterminal.keys"
        static let passwords = "dev.superterminal.passwords"
        static let accessTokens = "dev.superterminal.cloudflare.tokens"
        static let serviceTokens = "dev.superterminal.cloudflare.servicetokens"
        static let assistant = "dev.superterminal.assistant"
        static let vncPasswords = "dev.superterminal.vnc"
        static let appLock = "dev.superterminal.applock"
    }

    private let store: any SecureStore

    init(store: any SecureStore = KeychainSecureStore()) {
        self.store = store
    }

    // MARK: - SSH private keys

    /// Stores private key material.
    ///
    /// Biometric protection is per-key rather than global: a key used for a production
    /// jump host deserves a Face ID prompt, while one for a scratch VM does not, and
    /// forcing the same answer for both trains people to turn the feature off.
    ///
    /// `syncToICloud` puts the key in iCloud Keychain. Apple forbids combining that with
    /// biometric access control, so asking for both is refused rather than quietly
    /// dropping one of them.
    func storePrivateKey(_ pem: String, id: UUID, requireBiometrics: Bool, syncToICloud: Bool = false) throws {
        if requireBiometrics, syncToICloud { throw CredentialVaultError.biometricKeyCannotSync }
        let protection: SecureStoreProtection = if requireBiometrics {
            .biometricThisDeviceOnly
        } else if syncToICloud {
            .whenUnlockedSynchronizable
        } else {
            .whenUnlockedThisDeviceOnly
        }
        try store.set(
            Data(pem.utf8),
            for: SecureStoreKey(service: Service.privateKeys, account: id.uuidString),
            protection: protection,
            prompt: nil
        )
    }

    func loadPrivateKey(id: UUID, prompt: String?) throws -> String {
        let data = try store.get(
            SecureStoreKey(service: Service.privateKeys, account: id.uuidString),
            prompt: prompt
        )
        guard let pem = String(data: data, encoding: .utf8) else {
            throw SecureStoreError.itemNotFound
        }
        return pem
    }

    /// Whether the secret for a key record is on this device. A record can arrive by
    /// sync without its private key, and the list must say so rather than fail on use.
    /// Attribute-only, so a biometric key is never prompted for just to be listed.
    func hasPrivateKey(id: UUID) -> Bool {
        ((try? store.accounts(inService: Service.privateKeys)) ?? []).contains(id.uuidString)
    }

    func deletePrivateKey(id: UUID) throws {
        try store.remove(SecureStoreKey(service: Service.privateKeys, account: id.uuidString))
    }

    // MARK: - Passwords

    func storePassword(_ password: String, hostID: UUID) throws {
        try store.set(
            Data(password.utf8),
            for: SecureStoreKey(service: Service.passwords, account: hostID.uuidString),
            protection: .whenUnlockedThisDeviceOnly,
            prompt: nil
        )
    }

    func loadPassword(hostID: UUID) throws -> String? {
        guard let data = try store.getIfPresent(
            SecureStoreKey(service: Service.passwords, account: hostID.uuidString)
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func deletePassword(hostID: UUID) throws {
        try store.remove(SecureStoreKey(service: Service.passwords, account: hostID.uuidString))
    }

    // MARK: - Screen sharing passwords (D-022)

    /// This device only, like the SSH password, and deleted with the screen.
    ///
    /// Keyed by the screen's own id (D-027). The `hostID` variants below exist only for
    /// the migration, which moves a password from the SSH connection that used to own it.
    func storeVNCPassword(_ password: String, screenID: UUID) throws {
        try store.set(
            Data(password.utf8),
            for: SecureStoreKey(service: Service.vncPasswords, account: screenID.uuidString),
            protection: .whenUnlockedThisDeviceOnly,
            prompt: nil
        )
    }

    func loadVNCPassword(screenID: UUID) throws -> String? {
        guard let data = try store.getIfPresent(
            SecureStoreKey(service: Service.vncPasswords, account: screenID.uuidString)
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func hasVNCPassword(screenID: UUID) -> Bool {
        ((try? store.accounts(inService: Service.vncPasswords)) ?? []).contains(screenID.uuidString)
    }

    func deleteVNCPassword(screenID: UUID) throws {
        try store.remove(SecureStoreKey(service: Service.vncPasswords, account: screenID.uuidString))
    }

    // Migration only (D-027): where a VNC password used to live, under the SSH connection.
    // Nothing writes there any more, so the setter exists only for the migration's test.
    #if DEBUG
    func storeLegacyVNCPassword(_ password: String, hostID: UUID) throws {
        try store.set(
            Data(password.utf8),
            for: SecureStoreKey(service: Service.vncPasswords, account: hostID.uuidString),
            protection: .whenUnlockedThisDeviceOnly,
            prompt: nil
        )
    }
    #endif

    func loadVNCPassword(hostID: UUID) throws -> String? {
        guard let data = try store.getIfPresent(
            SecureStoreKey(service: Service.vncPasswords, account: hostID.uuidString)
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func hasVNCPassword(hostID: UUID) -> Bool {
        ((try? store.accounts(inService: Service.vncPasswords)) ?? []).contains(hostID.uuidString)
    }

    func deleteVNCPassword(hostID: UUID) throws {
        try store.remove(SecureStoreKey(service: Service.vncPasswords, account: hostID.uuidString))
    }

    // MARK: - App lock (D-023)

    /// The passcode's derivation, never the passcode; this device only.
    func storeAppPasscode(_ record: PasscodeRecord) throws {
        try store.set(
            try JSONEncoder().encode(record),
            for: SecureStoreKey(service: Service.appLock, account: "passcode"),
            protection: .whenUnlockedThisDeviceOnly,
            prompt: nil
        )
    }

    func loadAppPasscode() throws -> PasscodeRecord? {
        guard let data = try store.getIfPresent(SecureStoreKey(service: Service.appLock, account: "passcode")) else { return nil }
        return try JSONDecoder().decode(PasscodeRecord.self, from: data)
    }

    var hasAppPasscode: Bool {
        ((try? store.accounts(inService: Service.appLock)) ?? []).contains("passcode")
    }

    func deleteAppPasscode() throws {
        try store.remove(SecureStoreKey(service: Service.appLock, account: "passcode"))
    }

    // MARK: - Cloudflare Access tokens

    /// Access tokens use `afterFirstUnlock` because a reconnect may run while the device
    /// is locked in the user's pocket; the key material that would actually let someone
    /// in stays at `whenUnlocked`.
    func storeAccessToken(_ token: String, appIdentifier: String) throws {
        try store.set(
            Data(token.utf8),
            for: SecureStoreKey(service: Service.accessTokens, account: appIdentifier),
            protection: .afterFirstUnlockThisDeviceOnly,
            prompt: nil
        )
    }

    func loadAccessToken(appIdentifier: String) throws -> String? {
        guard let data = try store.getIfPresent(
            SecureStoreKey(service: Service.accessTokens, account: appIdentifier)
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func deleteAccessToken(appIdentifier: String) throws {
        try store.remove(SecureStoreKey(service: Service.accessTokens, account: appIdentifier))
    }

    /// Signs out of every Cloudflare Access application.
    func deleteAllAccessTokens() throws {
        try store.removeAll(inService: Service.accessTokens)
    }

    // MARK: - Assistant provider key

    /// The user's key for the assistant's provider (D-020): this device only, never
    /// synced, read at request time and put in one header.
    func storeAssistantKey(_ key: String) throws {
        try store.set(
            Data(key.utf8),
            for: SecureStoreKey(service: Service.assistant, account: "provider"),
            protection: .whenUnlockedThisDeviceOnly,
            prompt: nil
        )
    }

    func loadAssistantKey() throws -> String? {
        guard let data = try store.getIfPresent(SecureStoreKey(service: Service.assistant, account: "provider")) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func deleteAssistantKey() throws {
        try store.remove(SecureStoreKey(service: Service.assistant, account: "provider"))
    }

    // MARK: - Wholesale deletion

    /// Removes every secret this app holds. Used by "delete all data", where leaving a
    /// single forgotten Keychain item behind would defeat the point.
    // MARK: - Cloudflare Access service tokens

    private struct StoredServiceToken: Codable { var clientID: String; var secret: String }

    /// A long-lived machine credential: this device only, never synchronised, and deleted
    /// with the connection it belongs to.
    func storeServiceToken(clientID: String, secret: String, hostID: UUID) throws {
        let data = try JSONEncoder().encode(StoredServiceToken(clientID: clientID, secret: secret))
        try store.set(data, for: SecureStoreKey(service: Service.serviceTokens, account: hostID.uuidString), protection: .whenUnlockedThisDeviceOnly, prompt: nil)
    }

    func loadServiceToken(hostID: UUID) throws -> AccessServiceToken? {
        guard let data = try store.getIfPresent(SecureStoreKey(service: Service.serviceTokens, account: hostID.uuidString)) else { return nil }
        let stored = try JSONDecoder().decode(StoredServiceToken.self, from: data)
        return AccessServiceToken(clientID: stored.clientID, clientSecret: stored.secret)
    }

    func hasServiceToken(hostID: UUID) -> Bool {
        ((try? store.accounts(inService: Service.serviceTokens)) ?? []).contains(hostID.uuidString)
    }

    func deleteServiceToken(hostID: UUID) throws {
        try store.remove(SecureStoreKey(service: Service.serviceTokens, account: hostID.uuidString))
    }

    // A screen published through its own Cloudflare Tunnel keeps its token the same way
    // (D-029): this device only, never synchronised, deleted with the screen.
    func storeServiceToken(clientID: String, secret: String, screenID: UUID) throws {
        try storeServiceToken(clientID: clientID, secret: secret, hostID: screenID)
    }

    func loadServiceToken(screenID: UUID) throws -> AccessServiceToken? {
        try loadServiceToken(hostID: screenID)
    }

    func hasServiceToken(screenID: UUID) -> Bool { hasServiceToken(hostID: screenID) }

    func deleteServiceToken(screenID: UUID) throws { try deleteServiceToken(hostID: screenID) }

    func deleteEverything() throws {
        for service in [Service.privateKeys, Service.passwords, Service.accessTokens, Service.serviceTokens, Service.assistant, Service.vncPasswords, Service.appLock] {
            try store.removeAll(inService: service)
        }
    }
}

enum CredentialVaultError: Error, LocalizedError {
    /// Apple's Keychain rejects synchronisable items that carry access control.
    case biometricKeyCannotSync

    var errorDescription: String? {
        switch self {
        case .biometricKeyCannotSync:
            String(localized: "A key protected by Face ID or Touch ID cannot be stored in iCloud Keychain. Turn one of the two off.")
        }
    }
}
