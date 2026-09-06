import CommonCrypto
import Foundation
import LocalAuthentication
import Observation
import STCore
import SwiftUI
import UIKit

/// A passcode as it is stored: never the passcode, only what PBKDF2 makes of it with a
/// salt of its own, so two devices with the same passcode hold different records and
/// nothing in the Keychain can be turned back into the passcode.
struct PasscodeRecord: Codable, Equatable, Sendable {
    var salt: Data
    var rounds: Int
    var hash: Data

    static let defaultRounds = 200_000
    static let hashLength = 32

    static func make(_ passcode: String, rounds: Int = defaultRounds) -> PasscodeRecord {
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        return PasscodeRecord(salt: salt, rounds: rounds, hash: derive(passcode, salt: salt, rounds: rounds))
    }

    /// Constant-time comparison: a wrong passcode takes exactly as long as a right one.
    func matches(_ passcode: String) -> Bool {
        let candidate = Self.derive(passcode, salt: salt, rounds: rounds)
        guard candidate.count == hash.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(candidate, hash) { difference |= a ^ b }
        return difference == 0
    }

    static func derive(_ passcode: String, salt: Data, rounds: Int) -> Data {
        var derived = Data(count: hashLength)
        let password = Array(passcode.utf8)
        let status = derived.withUnsafeMutableBytes { output in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    password.map { CChar(bitPattern: $0) }, password.count,
                    saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds),
                    output.baseAddress?.assumingMemoryBound(to: UInt8.self), hashLength
                )
            }
        }
        precondition(status == kCCSuccess, "PBKDF2 failed: \(status)")
        return derived
    }
}

/// What a passcode has to be. Short, because it guards the app on a device that already
/// has its own passcode; not trivially short.
enum PasscodePolicy {
    static let minimumLength = 4

    static func problems(_ passcode: String) -> [String] {
        var problems: [String] = []
        if passcode.count < minimumLength { problems.append(String(localized: "Use at least \(minimumLength) characters.")) }
        if passcode.contains(where: \.isNewline) { problems.append(String(localized: "A passcode cannot contain a line break.")) }
        return problems
    }
}

/// How long a wrong guess costs. Guessing is slowed, never punished with data loss: the
/// SSH keys behind the lock are the user's, and a child at the screen is not an attacker.
enum AppLockBackoff {
    static func delay(afterFailures failures: Int) -> TimeInterval {
        switch failures {
        case ..<5: 0
        case 5 ..< 8: 30
        case 8 ..< 10: 60
        default: 300
        }
    }
}

/// When the lock engages after the app was put away.
enum AppLockGrace: Int, CaseIterable, Identifiable, Sendable {
    case immediately = 0
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .immediately: String(localized: "Immediately")
        case .oneMinute: String(localized: "After 1 minute")
        case .fiveMinutes: String(localized: "After 5 minutes")
        case .fifteenMinutes: String(localized: "After 15 minutes")
        }
    }

    /// Whether the lock should engage `elapsed` seconds after the app went to the background.
    func shouldLock(afterBackgroundFor elapsed: TimeInterval) -> Bool {
        elapsed >= TimeInterval(rawValue)
    }
}

enum BiometryKind: Equatable, Sendable {
    case none, touchID, faceID, opticID

    var title: String {
        switch self {
        case .none: String(localized: "Biometrics")
        case .touchID: "Touch ID"
        case .faceID: "Face ID"
        case .opticID: "Optic ID"
        }
    }

    var systemImage: String {
        switch self {
        case .none: "lock"
        case .touchID: "touchid"
        case .faceID: "faceid"
        case .opticID: "opticid"
        }
    }
}

/// The system's biometric check, behind a protocol so the lock's rules can be tested
/// without a face. The real one is `LAContext`; the app never sees biometric data.
protocol BiometricAuthenticating: Sendable {
    var kind: BiometryKind { get }
    func authenticate(reason: String) async -> Bool
}

struct SystemBiometrics: BiometricAuthenticating {
    var kind: BiometryKind {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return .none }
        switch context.biometryType {
        case .touchID: return .touchID
        case .faceID: return .faceID
        case .opticID: return .opticID
        default: return .none
        }
    }

    func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = String(localized: "Use Passcode")
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)) ?? false
    }
}

/// The app lock (D-023): a passcode of the app's own, Face ID or Touch ID in front of it
/// when the user allows, engaged at launch and when the app comes back after the grace
/// period. The rules live here; the window that shows them is `AppLockWindows`.
@Observable
@MainActor
final class AppLock {
    /// Engaged, and still on: turning the lock off — in Settings, or by deleting all data
    /// — releases a lock that is showing, rather than leaving a screen nothing can unlock.
    var isLocked: Bool { locked && isEnabled }
    private var locked = false
    private(set) var failedAttempts = 0
    /// When the next guess may be tried, during a backoff.
    private(set) var retryAfter: Date?
    /// Whether the system's biometric prompt is up, so the lock screen does not stack two.
    private(set) var isAuthenticating = false

    private let settings: AppSettings
    private let vault: CredentialVault
    private let biometrics: any BiometricAuthenticating
    private let clock: @Sendable () -> Date
    private let log: STLogger
    private var backgroundedAt: Date?
    private var biometricsOfferedForThisLock = false

    init(
        settings: AppSettings,
        vault: CredentialVault,
        biometrics: any BiometricAuthenticating = SystemBiometrics(),
        clock: @escaping @Sendable () -> Date = { Date() },
        log: STLogger
    ) {
        self.settings = settings
        self.vault = vault
        self.biometrics = biometrics
        self.clock = clock
        self.log = log.child(subsystem: "lock")
        locked = isEnabled
    }

    /// On, with a passcode in the Keychain. Deleting all data removes the record, and
    /// with it the lock, so nothing can lock the user out of an empty app.
    var isEnabled: Bool { settings.appLockEnabled && vault.hasAppPasscode }

    var biometryKind: BiometryKind { biometrics.kind }
    var usesBiometrics: Bool { settings.appLockUsesBiometrics && biometryKind != .none }
    var grace: AppLockGrace { AppLockGrace(rawValue: settings.appLockGraceSeconds) ?? .immediately }

    // MARK: - Engaging

    func handleScenePhase(_ phase: ScenePhase) {
        guard isEnabled else { return }
        switch phase {
        case .background:
            if backgroundedAt == nil { backgroundedAt = clock() }
        case .active:
            if let since = backgroundedAt, grace.shouldLock(afterBackgroundFor: clock().timeIntervalSince(since)) {
                lockNow()
            }
            backgroundedAt = nil
        default:
            break
        }
    }

    func lockNow() {
        guard isEnabled, !locked else { return }
        locked = true
        biometricsOfferedForThisLock = false
        log.info("locked")
    }

    // MARK: - Unlocking

    /// Whether the lock screen should offer biometrics on its own when it appears —
    /// once per lock, so a cancelled prompt does not come straight back.
    func takeAutomaticBiometricsOffer() -> Bool {
        guard usesBiometrics, !biometricsOfferedForThisLock else { return false }
        biometricsOfferedForThisLock = true
        return true
    }

    @discardableResult
    func unlockWithBiometrics() async -> Bool {
        guard isLocked, usesBiometrics, !isAuthenticating else { return false }
        isAuthenticating = true
        defer { isAuthenticating = false }
        let passed = await biometrics.authenticate(reason: String(localized: "Unlock SuperTerminal"))
        if passed { unlocked() }
        return passed
    }

    /// The seconds left before another guess is allowed, or nil.
    var secondsUntilRetry: Int? {
        guard let retryAfter else { return nil }
        let left = retryAfter.timeIntervalSince(clock())
        return left > 0 ? Int(left.rounded(.up)) : nil
    }

    @discardableResult
    func unlock(passcode: String) -> Bool {
        guard isLocked else { return true }
        if secondsUntilRetry != nil { return false }
        if (try? vault.loadAppPasscode())?.matches(passcode) == true {
            unlocked()
            return true
        }
        failedAttempts += 1
        let delay = AppLockBackoff.delay(afterFailures: failedAttempts)
        retryAfter = delay > 0 ? clock().addingTimeInterval(delay) : nil
        log.info("wrong passcode", ["attempts": "\(failedAttempts)"])
        return false
    }

    private func unlocked() {
        locked = false
        failedAttempts = 0
        retryAfter = nil
        backgroundedAt = nil
        log.info("unlocked")
    }

    // MARK: - Setting up

    /// Turns the lock on with `passcode`. Anything the policy rejects is thrown back.
    func enable(passcode: String) throws {
        let problems = PasscodePolicy.problems(passcode)
        guard problems.isEmpty else { throw AppLockError.weakPasscode(problems) }
        try vault.storeAppPasscode(PasscodeRecord.make(passcode))
        settings.appLockEnabled = true
        // Turning the lock on never locks the screen the user is on — including when an
        // engagement from before (a previous launch's state, since cleared) is still held.
        locked = false
        log.info("lock enabled")
    }

    /// Verifies the current passcode, or biometrics, before anything is changed.
    func confirmIdentity(passcode: String) -> Bool {
        (try? vault.loadAppPasscode())?.matches(passcode) == true
    }

    func changePasscode(to passcode: String) throws {
        let problems = PasscodePolicy.problems(passcode)
        guard problems.isEmpty else { throw AppLockError.weakPasscode(problems) }
        try vault.storeAppPasscode(PasscodeRecord.make(passcode))
        log.info("passcode changed")
    }

    func disable() {
        try? vault.deleteAppPasscode()
        settings.appLockEnabled = false
        locked = false
        failedAttempts = 0
        retryAfter = nil
        log.info("lock disabled")
    }
}

enum AppLockError: Error, LocalizedError, Equatable {
    case weakPasscode([String])

    var errorDescription: String? {
        switch self {
        case let .weakPasscode(problems): problems.joined(separator: " ")
        }
    }
}

/// Puts the lock screen in a window of its own above everything else in each scene — a
/// sheet that happened to be open, a terminal, another window on iPad — rather than in
/// the view tree, where a presented sheet would stay visible above it (D-023).
@MainActor
final class AppLockWindows {
    private var windows: [ObjectIdentifier: UIWindow] = [:]
    /// The window that was key before the lock covered the scene, so it can be made key
    /// again — `scene.windows` is unordered and on iPad includes UIKit's own keyboard
    /// windows, so "the first one that is not the lock" is not the app's window (D-025).
    private var previousKeyWindow: [ObjectIdentifier: UIWindow] = [:]

    func show(in scene: UIWindowScene, content: @escaping () -> AnyView) {
        let key = ObjectIdentifier(scene)
        if previousKeyWindow[key] == nil {
            previousKeyWindow[key] = scene.windows.first { $0.isKeyWindow } ?? scene.keyWindow
        }
        if let existing = windows[key] {
            existing.isHidden = false
            existing.makeKeyAndVisible()
            return
        }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        let host = UIHostingController(rootView: content())
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.accessibilityViewIsModal = true
        windows[key] = window
        window.makeKeyAndVisible()
        window.alpha = 0
        UIView.animate(withDuration: 0.2) { window.alpha = 1 }
    }

    func hide(in scene: UIWindowScene) {
        let key = ObjectIdentifier(scene)
        guard let window = windows[key] else { return }
        UIView.animate(withDuration: 0.25, animations: { window.alpha = 0 }) { _ in
            window.isHidden = true
            window.rootViewController = nil
        }
        windows[key] = nil
        // The window that had the keyboard before the lock takes it back. The terminal
        // re-acquires first-responder status itself once the lock releases, through
        // `wantsKeyboard`.
        let restored = previousKeyWindow[key] ?? scene.windows.first { !$0.isHidden && $0 !== window }
        previousKeyWindow[key] = nil
        restored?.makeKey()
    }

    func hideAll() {
        for (_, window) in windows {
            window.isHidden = true
            window.rootViewController = nil
        }
        windows = [:]
        previousKeyWindow = [:]
    }
}

/// Reports the window scene a SwiftUI view ended up in, which is what a lock window
/// has to be attached to.
struct WindowSceneReader: UIViewRepresentable {
    let onScene: (UIWindowScene) -> Void

    func makeUIView(context: Context) -> SceneReportingView {
        let view = SceneReportingView()
        view.onScene = onScene
        return view
    }

    func updateUIView(_ view: SceneReportingView, context: Context) {
        view.onScene = onScene
        view.report()
    }

    final class SceneReportingView: UIView {
        var onScene: ((UIWindowScene) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }
        func report() {
            if let scene = window?.windowScene { onScene?(scene) }
        }
    }
}
