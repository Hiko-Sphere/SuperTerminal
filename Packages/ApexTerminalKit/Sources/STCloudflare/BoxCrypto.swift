import Foundation
import Sodium

/// The NaCl `crypto_box` operations the Cloudflare Access login flow needs.
///
/// Cloudflare's login-helper seals credentials with `crypto_box` — X25519 key
/// agreement, XSalsa20 for confidentiality and Poly1305 for integrity — so the client
/// must implement exactly that construction. ApexTerminal does not reimplement any
/// of it: the only conformance used in the app delegates to libsodium, whose author
/// maintains the Swift wrapper. The protocol exists so tests can exercise the
/// surrounding flow, never to substitute a weaker implementation at runtime.
public protocol BoxCrypto: Sendable {
    /// A freshly generated ephemeral X25519 key pair.
    func generateKeyPair() throws -> BoxKeyPair

    /// Opens `nonceAndCiphertext` (24-byte nonce followed by the sealed box).
    /// Returns `nil` when authentication fails — there is no unauthenticated path.
    func open(nonceAndCiphertext: Data, senderPublicKey: Data, recipientSecretKey: Data) -> Data?
}

public struct BoxKeyPair: Sendable {
    public let publicKey: Data
    public let secretKey: Data

    public init(publicKey: Data, secretKey: Data) {
        self.publicKey = publicKey
        self.secretKey = secretKey
    }
}

/// libsodium-backed ``BoxCrypto``.
public struct SodiumBoxCrypto: BoxCrypto {
    public init() {}

    public func generateKeyPair() throws -> BoxKeyPair {
        guard let pair = Sodium().box.keyPair() else {
            throw AccessError.loginFailed("libsodium could not generate an ephemeral key pair")
        }
        return BoxKeyPair(publicKey: Data(pair.publicKey), secretKey: Data(pair.secretKey))
    }

    public func open(nonceAndCiphertext: Data, senderPublicKey: Data, recipientSecretKey: Data) -> Data? {
        Sodium().box.open(
            nonceAndAuthenticatedCipherText: Array(nonceAndCiphertext),
            senderPublicKey: Array(senderPublicKey),
            recipientSecretKey: Array(recipientSecretKey)
        ).map { Data($0) }
    }
}
