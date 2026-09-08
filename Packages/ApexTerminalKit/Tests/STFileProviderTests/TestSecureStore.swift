import Foundation
import STSecureStore

/// An in-memory ``SecureStore`` for these tests only.
///
/// It exists so a test can put a key where ``DomainConnection`` looks for one without
/// touching the login Keychain of whoever is running the suite. It is in the test target,
/// not in the library, so there is no way for it to end up in a shipping build.
final class TestSecureStore: SecureStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [SecureStoreKey: Data] = [:]
    /// Items that behave like a Face-ID-protected key: readable only when a prompt is
    /// offered, which is exactly what the extension refuses to do.
    private var interactive: Set<SecureStoreKey> = []

    func set(_ data: Data, for key: SecureStoreKey, protection: SecureStoreProtection, prompt: String?) throws {
        lock.withLock {
            items[key] = data
            if protection == .biometricThisDeviceOnly { interactive.insert(key) } else { interactive.remove(key) }
        }
    }

    func get(_ key: SecureStoreKey, prompt: String?) throws -> Data {
        try lock.withLock {
            if interactive.contains(key), prompt == nil { throw SecureStoreError.interactionNotAllowed }
            guard let data = items[key] else { throw SecureStoreError.itemNotFound }
            return data
        }
    }

    func remove(_ key: SecureStoreKey) throws {
        lock.withLock { items.removeValue(forKey: key); interactive.remove(key) }
    }

    func accounts(inService service: String) throws -> [String] {
        lock.withLock { items.keys.filter { $0.service == service }.map(\.account).sorted() }
    }

    func removeAll(inService service: String) throws {
        lock.withLock {
            for key in items.keys where key.service == service {
                items.removeValue(forKey: key)
                interactive.remove(key)
            }
        }
    }
}
