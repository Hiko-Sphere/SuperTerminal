import Foundation
import STCore
import SwiftUI
import Testing
@testable import SuperTerminal

/// The app lock's rules (D-023) with a biometric check that answers what the test says
/// and a clock the test moves. The Keychain and the passcode derivation are real.
@Suite("App lock", .serialized)
struct AppLockTests {
    final class FakeBiometrics: BiometricAuthenticating, @unchecked Sendable {
        var kind: BiometryKind
        var passes: Bool
        var prompts = 0
        init(kind: BiometryKind, passes: Bool) { self.kind = kind; self.passes = passes }
        func authenticate(reason: String) async -> Bool { prompts += 1; return passes }
    }

    final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
    }

    @MainActor
    private func makeLock(biometrics: FakeBiometrics = FakeBiometrics(kind: .faceID, passes: true)) -> (AppLock, AppSettings, CredentialVault, Clock) {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "lock-test-\(UUID().uuidString)") ?? .standard)
        let vault = CredentialVault()
        try? vault.deleteAppPasscode()
        let clock = Clock()
        let lock = AppLock(settings: settings, vault: vault, biometrics: biometrics, clock: { clock.now }, log: .disabled)
        return (lock, settings, vault, clock)
    }

    @Test("A passcode record never holds the passcode, matches only its own, and survives encoding")
    func passcodeRecord() throws {
        let record = PasscodeRecord.make("correct horse", rounds: 1_000)
        #expect(record.matches("correct horse"))
        #expect(!record.matches("correct horse "))
        #expect(!record.matches(""))
        #expect(record.hash.count == 32 && record.salt.count == 16)
        #expect(!String(decoding: record.hash, as: UTF8.self).contains("horse"))
        #expect(PasscodeRecord.make("correct horse", rounds: 1_000).hash != record.hash, "a fresh salt every time")
        let back = try JSONDecoder().decode(PasscodeRecord.self, from: JSONEncoder().encode(record))
        #expect(back == record && back.matches("correct horse"))
    }

    @Test("The policy and the backoff table")
    func policyAndBackoff() {
        #expect(PasscodePolicy.problems("1234").isEmpty)
        #expect(!PasscodePolicy.problems("123").isEmpty)
        #expect(!PasscodePolicy.problems("12\n34").isEmpty)
        #expect(AppLockBackoff.delay(afterFailures: 4) == 0)
        #expect(AppLockBackoff.delay(afterFailures: 5) == 30)
        #expect(AppLockBackoff.delay(afterFailures: 8) == 60)
        #expect(AppLockBackoff.delay(afterFailures: 10) == 300)
        #expect(AppLockGrace.oneMinute.shouldLock(afterBackgroundFor: 59) == false)
        #expect(AppLockGrace.oneMinute.shouldLock(afterBackgroundFor: 60))
        #expect(AppLockGrace.immediately.shouldLock(afterBackgroundFor: 0))
    }

    @Test("Enabling needs a passcode the policy accepts, and locks nothing until the app goes away")
    @MainActor func enabling() throws {
        let (lock, settings, vault, _) = makeLock()
        #expect(!lock.isEnabled && !lock.isLocked)
        #expect(throws: AppLockError.self) { try lock.enable(passcode: "12") }
        #expect(!lock.isEnabled)
        try lock.enable(passcode: "open sesame")
        #expect(lock.isEnabled && settings.appLockEnabled && vault.hasAppPasscode)
        #expect(!lock.isLocked, "turning the lock on does not lock the user out of the screen they are on")
        lock.disable()
        #expect(!lock.isEnabled && !vault.hasAppPasscode && !settings.appLockEnabled)
    }

    @Test("The lock engages after the grace period, not before")
    @MainActor func gracePeriod() throws {
        let (lock, settings, _, clock) = makeLock()
        try lock.enable(passcode: "open sesame")
        settings.appLockGraceSeconds = AppLockGrace.oneMinute.rawValue
        lock.handleScenePhase(.background)
        clock.now += 30
        lock.handleScenePhase(.active)
        #expect(!lock.isLocked, "back within a minute: still open")
        lock.handleScenePhase(.background)
        clock.now += 61
        lock.handleScenePhase(.active)
        #expect(lock.isLocked)
        lock.disable()
    }

    @Test("A wrong passcode counts, five of them cost thirty seconds, and the right one clears everything")
    @MainActor func passcodeUnlock() throws {
        let (lock, _, _, clock) = makeLock(biometrics: FakeBiometrics(kind: .none, passes: false))
        try lock.enable(passcode: "open sesame")
        lock.lockNow()
        #expect(lock.isLocked)
        for _ in 0 ..< 4 { #expect(!lock.unlock(passcode: "nope")) }
        #expect(lock.failedAttempts == 4 && lock.secondsUntilRetry == nil)
        #expect(!lock.unlock(passcode: "nope"))
        #expect(lock.failedAttempts == 5 && lock.secondsUntilRetry == 30)
        #expect(!lock.unlock(passcode: "open sesame"), "no guess is taken during the backoff, not even the right one")
        clock.now += 31
        #expect(lock.secondsUntilRetry == nil)
        #expect(lock.unlock(passcode: "open sesame"))
        #expect(!lock.isLocked && lock.failedAttempts == 0)
        lock.disable()
    }

    @Test("Biometrics unlock when the system says yes, and only when allowed")
    @MainActor func biometrics() async throws {
        let biometrics = FakeBiometrics(kind: .faceID, passes: false)
        let (lock, settings, _, _) = makeLock(biometrics: biometrics)
        try lock.enable(passcode: "open sesame")
        lock.lockNow()
        #expect(lock.takeAutomaticBiometricsOffer(), "offered once when the screen appears")
        #expect(!lock.takeAutomaticBiometricsOffer(), "and not again for the same lock")
        #expect(await lock.unlockWithBiometrics() == false)
        #expect(lock.isLocked)
        biometrics.passes = true
        #expect(await lock.unlockWithBiometrics())
        #expect(!lock.isLocked && biometrics.prompts == 2)

        settings.appLockUsesBiometrics = false
        lock.lockNow()
        #expect(!lock.usesBiometrics)
        #expect(await lock.unlockWithBiometrics() == false, "turned off in Settings: no prompt")
        #expect(biometrics.prompts == 2)
        lock.disable()
    }

    @Test("Without a record the setting alone locks nothing — deleting all data cannot lock the user out")
    @MainActor func settingWithoutRecord() throws {
        let (lock, settings, vault, _) = makeLock()
        try lock.enable(passcode: "open sesame")
        try vault.deleteAppPasscode()
        #expect(settings.appLockEnabled && !lock.isEnabled)
        lock.lockNow()
        #expect(!lock.isLocked)
        settings.appLockEnabled = false
    }

    @Test("Turning the lock off while it is showing releases it, and turning it on never locks the current screen")
    @MainActor func disablingWhileLockedReleases() throws {
        let (lock, settings, vault, _) = makeLock()
        try lock.enable(passcode: "open sesame")
        lock.lockNow()
        #expect(lock.isLocked)
        // Deleting all data removes the record — a seeded UI run does the same at launch.
        try vault.deleteAppPasscode()
        #expect(!lock.isLocked, "no record, no lock — whatever the screen showed a moment ago")
        // Turning it on again must not resurrect the engagement held from before.
        try lock.enable(passcode: "open sesame")
        #expect(!lock.isLocked, "enabling never locks the screen the user is on")
        lock.lockNow()
        #expect(lock.isLocked)
        settings.appLockEnabled = false
        #expect(!lock.isLocked, "and the setting alone going off releases it too")
        lock.disable()
    }
}
