import Crypto
import Foundation
import LocalAuthentication
import NIOSSH
import STCore
import Security

/// SSH keys whose private half lives in the Secure Enclave and never exists outside it.
///
/// The Secure Enclave holds one signing curve, NIST P-256, so the SSH algorithm is fixed
/// at `ecdsa-sha2-nistp256`. That is the whole compatibility story: any OpenSSH built in
/// the last decade accepts such a key in `authorized_keys`, and the server cannot tell —
/// and does not need to know — that the signature came from dedicated hardware.
///
/// What the enclave changes is what an attacker with the device can take. A key file, or
/// a Keychain item holding one, is bytes: read them and the key is yours wherever you go.
/// An enclave key is not bytes. ``Handle/blob`` is a wrapped reference that only this
/// device's enclave can unwrap, so copying it off the phone yields nothing. Apple states
/// the property directly: "you can't extract the private key from the Secure Enclave"
/// (*Storing Keys in the Secure Enclave*, Apple Developer Documentation).
///
/// The cost is that such a key cannot be backed up, cannot go to another device, and
/// cannot be recovered — losing the device loses the key. The UI says so before one is
/// created, and the backup refuses to pretend otherwise.
public enum SecureEnclaveSSHKey {
    /// Whether this device has a usable Secure Enclave.
    ///
    /// True on every iPhone and iPad with an A7 or later — and, measured on this project,
    /// true in the iOS Simulator on Apple silicon, where CryptoKit reaches the host Mac's
    /// enclave. What the Simulator does *not* have is biometrics, so a key created there
    /// can only use ``AccessPolicy/deviceUnlocked``.
    public static var isAvailable: Bool { SecureEnclave.isAvailable }

    /// Whether this device can gate an enclave key behind Face ID, Touch ID or a
    /// passcode.
    ///
    /// False in the Simulator, which has an enclave but no biometrics: creating a key
    /// with a user-presence flag there fails inside LocalAuthentication with "This call
    /// is not supported on iOS Simulator". Asking first turns that into a sentence the UI
    /// can show before the user commits to a choice.
    public static var canRequireBiometrics: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
            && LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    /// When the enclave will agree to sign.
    public enum AccessPolicy: String, Sendable, Codable, CaseIterable, Identifiable {
        /// Signing needs nothing beyond an unlocked device. The key still cannot be
        /// copied off the device; it just does not ask a second time.
        case deviceUnlocked
        /// Every signature needs a fresh Face ID, Touch ID or passcode check, and the key
        /// stops working if the device's biometric enrolment changes — so someone who
        /// learns the passcode cannot enrol their own face and sign with it.
        case biometricsEachUse

        public var id: String { rawValue }

        var flags: SecAccessControlCreateFlags {
            switch self {
            case .deviceUnlocked: [.privateKeyUsage]
            case .biometricsEachUse: [.privateKeyUsage, .biometryCurrentSet]
            }
        }

        /// Whether a background process — the File Provider extension, a reconnect while
        /// the app is not frontmost — can use a key with this policy. Nobody is there to
        /// answer a biometric prompt, and raising one from the background would be worse
        /// than failing.
        public var worksUnattended: Bool { self == .deviceUnlocked }
    }

    /// A key that exists in the enclave, described by what can safely leave it.
    public struct Handle: Sendable {
        /// The enclave's wrapped reference to the private key. Meaningless on any other
        /// device, but still stored in the Keychain rather than in a file: an attacker
        /// who cannot use it also has no business enumerating it.
        public let blob: Data
        /// The `authorized_keys` line to paste on the server.
        public let publicKeyOpenSSH: String
        public let publicKey: SSHHostKey
        public var fingerprintSHA256: String { publicKey.fingerprintSHA256 }
        public let accessPolicy: AccessPolicy
    }

    /// Creates a key inside the enclave.
    ///
    /// - Parameter comment: the trailing comment on the public key line, as `ssh-keygen`
    ///   writes it; it is what a server administrator sees in `authorized_keys`.
    public static func generate(accessPolicy: AccessPolicy, comment: String) throws -> Handle {
        guard isAvailable else { throw SecureEnclaveKeyError.unavailable }
        guard accessPolicy == .deviceUnlocked || canRequireBiometrics else {
            // Checked here rather than left to fail deep inside CryptoKit, where the
            // error says "Authentication failure" and names neither the cause nor a fix.
            throw SecureEnclaveKeyError.biometricsUnavailable
        }

        var aclError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            // The strictest class an enclave key can carry: unusable while the device is
            // locked, and never present in a backup or on another device.
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            accessPolicy.flags,
            &aclError
        ) else {
            throw SecureEnclaveKeyError.accessControlRejected(
                String(describing: aclError?.takeRetainedValue())
            )
        }

        let key: SecureEnclave.P256.Signing.PrivateKey
        do {
            key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
        } catch {
            throw SecureEnclaveKeyError.creationFailed(String(describing: error))
        }

        let blob = SSHKeyGenerator.p256PublicKeyBlob(key.publicKey)
        let hostKey = SSHHostKey(algorithm: "ecdsa-sha2-nistp256", blob: blob)
        return Handle(
            blob: key.dataRepresentation,
            publicKeyOpenSSH: "\(hostKey.openSSHRepresentation) \(comment)",
            publicKey: hostKey,
            accessPolicy: accessPolicy
        )
    }

    /// Asks for Face ID or Touch ID up front and returns the context that proves it.
    ///
    /// A key with the ``AccessPolicy/biometricsEachUse`` policy raises its prompt at the
    /// moment the enclave is asked to sign — and SSH asks it to sign from a NIO event
    /// loop, where the call would block every other connection sharing that loop for as
    /// long as a person takes to look at their phone. Authenticating first moves the wait
    /// to the connecting task, where it belongs, and lets a cancellation be reported as
    /// "you cancelled" rather than as a handshake failure.
    ///
    /// The policy evaluated is `deviceOwnerAuthenticationWithBiometrics`, deliberately not
    /// the one that falls back to the passcode: the key's access control is
    /// `.biometryCurrentSet`, and a context authenticated by passcode would not satisfy
    /// it, so the fallback would buy a prompt that changes nothing. The reuse window is
    /// set so the signature a moment later is covered by this authentication.
    public static func authenticatedContext(reason: String) async throws -> LAContext {
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = LATouchIDAuthenticationMaximumAllowableReuseDuration
        context.localizedReason = reason
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) else {
                throw SecureEnclaveKeyError.authenticationFailed("evaluatePolicy returned false")
            }
        } catch let error as LAError where error.code == .userCancel || error.code == .appCancel || error.code == .systemCancel {
            throw SecureEnclaveKeyError.authenticationCancelled
        } catch let error as SecureEnclaveKeyError {
            throw error
        } catch {
            throw SecureEnclaveKeyError.authenticationFailed(String(describing: error))
        }
        return context
    }

    /// Rebuilds the signing key from a reference and an already-authenticated context —
    /// the one ``authenticatedContext(reason:)`` returned.
    public static func material(
        blob: Data,
        comment: String?,
        context: LAContext
    ) throws -> SSHPrivateKeyMaterial {
        try material(blob: blob, comment: comment, using: context)
    }

    /// Rebuilds the signing key from its stored reference, ready to authenticate with.
    ///
    /// - Parameter authenticationPrompt: shown in the Face ID / Touch ID sheet when the
    ///   key's policy asks for one. `nil` means no interaction is permitted, which is
    ///   what a background process must pass: a `biometricsEachUse` key then fails at the
    ///   first signature rather than silently waiting for someone who is not there.
    public static func material(
        blob: Data,
        comment: String?,
        authenticationPrompt: String?
    ) throws -> SSHPrivateKeyMaterial {
        let context = LAContext()
        if let authenticationPrompt {
            context.localizedReason = authenticationPrompt
        } else {
            // No prompt asked for: forbid interaction outright, so a background process
            // fails immediately instead of trying to raise a sheet in front of nobody.
            context.interactionNotAllowed = true
        }
        return try material(blob: blob, comment: comment, using: context)
    }

    private static func material(
        blob: Data,
        comment: String?,
        using context: LAContext
    ) throws -> SSHPrivateKeyMaterial {
        let key: SecureEnclave.P256.Signing.PrivateKey
        do {
            key = try SecureEnclave.P256.Signing.PrivateKey(
                dataRepresentation: blob,
                authenticationContext: context
            )
        } catch {
            throw SecureEnclaveKeyError.unusable(String(describing: error))
        }

        return SSHPrivateKeyMaterial(
            key: NIOSSHPrivateKey(secureEnclaveP256Key: key),
            algorithm: "ecdsa-sha2-nistp256",
            comment: comment,
            publicKey: SSHHostKey(
                algorithm: "ecdsa-sha2-nistp256",
                blob: SSHKeyGenerator.p256PublicKeyBlob(key.publicKey)
            )
        )
    }
}

/// What can go wrong with an enclave key, in terms a person can act on.
public enum SecureEnclaveKeyError: Error, Sendable, Equatable {
    /// This device has no Secure Enclave.
    case unavailable
    /// The access-control object could not be built — in practice, asking for biometrics
    /// where the platform has none.
    case accessControlRejected(String)
    /// A biometric policy was asked for on a device with no enrolled biometrics.
    case biometricsUnavailable
    /// The person dismissed the Face ID or Touch ID prompt.
    case authenticationCancelled
    /// The check itself failed or errored.
    case authenticationFailed(String)
    case creationFailed(String)
    /// The stored reference did not produce a usable key: the enclave has forgotten it
    /// (a restore onto another device, a reset), or its biometric enrolment changed.
    case unusable(String)

    public var stError: STError {
        switch self {
        case .unavailable:
            STError(
                category: .credential,
                message: String(localized: "This device has no Secure Enclave.", bundle: .module),
                recoverySuggestion: String(localized: "Generate an ordinary key instead; it is stored in the Keychain.", bundle: .module)
            )
        case .biometricsUnavailable:
            STError(
                category: .credential,
                message: String(localized: "Face ID and Touch ID are not set up on this device.", bundle: .module),
                recoverySuggestion: String(localized: "Set one up in Settings, or create the key so that it only needs the device to be unlocked.", bundle: .module)
            )
        case .authenticationCancelled:
            STError(
                category: .cancelled,
                message: String(localized: "Unlocking the key was cancelled.", bundle: .module),
                recoverySuggestion: String(localized: "Connect again and complete the Face ID or Touch ID check.", bundle: .module)
            )
        case let .authenticationFailed(detail):
            STError(
                category: .credential,
                message: String(localized: "Face ID or Touch ID could not confirm it was you.", bundle: .module),
                recoverySuggestion: String(localized: "Try again. This key is set to require a biometric check before every use.", bundle: .module),
                underlyingDescription: detail
            )
        case let .accessControlRejected(detail):
            STError(
                category: .credential,
                message: String(localized: "This device cannot protect a key the way you asked.", bundle: .module),
                recoverySuggestion: String(localized: "Set up Face ID, Touch ID or a passcode, or choose “While the device is unlocked”.", bundle: .module),
                underlyingDescription: detail
            )
        case let .creationFailed(detail):
            STError(
                category: .credential,
                message: String(localized: "The Secure Enclave would not create the key.", bundle: .module),
                recoverySuggestion: String(localized: "Try again. If it keeps happening, generate an ordinary key instead; it is stored in the Keychain.", bundle: .module),
                underlyingDescription: detail
            )
        case let .unusable(detail):
            STError(
                category: .credential,
                message: String(localized: "This key is no longer usable on this device.", bundle: .module),
                recoverySuggestion: String(localized: "A Secure Enclave key cannot be restored or moved. Generate a new one and add its public key to the server.", bundle: .module),
                underlyingDescription: detail
            )
        }
    }
}
