import Foundation
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
    func storePrivateKey(_ pem: String, id: UUID, requireBiometrics: Bool) throws {
        try store.set(
            Data(pem.utf8),
            for: SecureStoreKey(service: Service.privateKeys, account: id.uuidString),
            protection: requireBiometrics ? .biometricThisDeviceOnly : .whenUnlockedThisDeviceOnly,
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

    // MARK: - Wholesale deletion

    /// Removes every secret this app holds. Used by "delete all data", where leaving a
    /// single forgotten Keychain item behind would defeat the point.
    func deleteEverything() throws {
        for service in [Service.privateKeys, Service.passwords, Service.accessTokens, Service.serviceTokens] {
            try store.removeAll(inService: service)
        }
    }
}
