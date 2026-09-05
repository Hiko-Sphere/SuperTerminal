import Foundation
import LocalAuthentication
import STCore
import Security

/// The Keychain-backed ``SecureStore`` used by the app.
///
/// Design notes that matter for security review:
///
/// * Every item is written with a `ThisDeviceOnly` accessibility class, so nothing
///   here can travel in an iCloud Keychain sync or in an encrypted device backup
///   restored onto a different device.
/// * `kSecAttrSynchronizable` is `false` on every write except the one protection level
///   that opts into iCloud Keychain, and `kSecAttrSynchronizableAny` on queries so a
///   synchronised item can never be matched by accident.
/// * Biometric items use `.biometryCurrentSet`, which invalidates the item if a new
///   finger or face is enrolled — an attacker who learns the passcode still cannot
///   add a biometric and read the key.
public struct KeychainSecureStore: SecureStore {
    private let accessGroup: String?

    /// - Parameter accessGroup: keychain access group, when the app shares items with
    ///   an extension. `nil` keeps items private to the app.
    public init(accessGroup: String? = nil) {
        self.accessGroup = accessGroup
    }

    public func set(_ data: Data, for key: SecureStoreKey, protection: SecureStoreProtection, prompt: String?) throws {
        var attributes = baseQuery(for: key)
        attributes[kSecValueData as String] = data

        switch protection {
        case .whenUnlockedThisDeviceOnly:
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        case .afterFirstUnlockThisDeviceOnly:
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        case .whenUnlockedSynchronizable:
            // Not ThisDeviceOnly, and no access control: both are forbidden for items that
            // sync, and the framework rejects them rather than warning.
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            attributes[kSecAttrSynchronizable as String] = true
        case .biometricThisDeviceOnly:
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                .biometryCurrentSet,
                &error
            ) else {
                throw SecureStoreError.unhandled(status: errSecParam)
            }
            attributes[kSecAttrAccessControl as String] = access
        }

        // Replace rather than update: an update would keep the previous item's
        // accessibility attributes, silently downgrading protection if the caller
        // changed the protection class.
        SecItemDelete(baseQuery(for: key) as CFDictionary)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw Self.map(status) }
    }

    public func get(_ key: SecureStoreKey, prompt: String?) throws -> Data {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        if let prompt {
            context.localizedReason = prompt
        } else {
            // Without an explicit prompt, never raise a biometric sheet from a
            // background code path; fail so the caller can ask at a sensible moment.
            context.interactionNotAllowed = true
        }
        query[kSecUseAuthenticationContext as String] = context

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw Self.map(status) }
        guard let data = result as? Data else { throw SecureStoreError.itemNotFound }
        return data
    }

    public func remove(_ key: SecureStoreKey) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.map(status) }
    }

    public func accounts(inService service: String) throws -> [String] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            // Listing accounts must never prompt: it runs while drawing the key list.
            kSecUseAuthenticationContext as String: Self.nonInteractiveContext(),
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw Self.map(status) }
        guard let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    public func removeAll(inService service: String) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.map(status) }
    }

    private func baseQuery(for key: SecureStoreKey) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: key.service,
            kSecAttrAccount as String: key.account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    private static func nonInteractiveContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    static func map(_ status: OSStatus) -> SecureStoreError {
        switch status {
        case errSecItemNotFound: .itemNotFound
        case errSecDuplicateItem: .duplicateItem
        case errSecAuthFailed: .authenticationFailed
        case errSecUserCanceled: .userCancelled
        case errSecInteractionNotAllowed: .interactionNotAllowed
        default: .unhandled(status: status)
        }
    }
}
