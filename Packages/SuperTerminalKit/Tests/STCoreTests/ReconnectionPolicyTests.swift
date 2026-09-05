import Foundation
import STCore
import Testing

@Suite("Reconnection policy")
struct ReconnectionPolicyTests {
    private let policy = ReconnectionPolicy(baseDelay: .seconds(1), maxDelay: .seconds(30), maxAttempts: 8)

    @Test("Delays double until they reach the ceiling")
    func delaysDouble() {
        // Pinned jitter of 1 gives the full delay, which is the value that must double.
        let delays = (1 ... 8).map { policy.delay(forAttempt: $0, randomFraction: 1) }
        #expect(delays[0] == .seconds(1))
        #expect(delays[1] == .seconds(2))
        #expect(delays[2] == .seconds(4))
        #expect(delays[3] == .seconds(8))
        #expect(delays[4] == .seconds(16))
        // Capped from here, not 32.
        #expect(delays[5] == .seconds(30))
        #expect(delays[7] == .seconds(30))
    }

    @Test("Jitter never drops below half nor above the whole delay")
    func jitterIsBounded() {
        for attempt in 1 ... 10 {
            let low = policy.delay(forAttempt: attempt, randomFraction: 0)
            let high = policy.delay(forAttempt: attempt, randomFraction: 1)
            #expect(low == high / 2)
            #expect(low > .zero, "a delay of zero would be a busy loop")
            #expect(high <= policy.maxDelay)
        }
    }

    @Test("Out-of-range randomness is clamped rather than trusted")
    func randomnessIsClamped() {
        #expect(policy.delay(forAttempt: 3, randomFraction: -5) == policy.delay(forAttempt: 3, randomFraction: 0))
        #expect(policy.delay(forAttempt: 3, randomFraction: 5) == policy.delay(forAttempt: 3, randomFraction: 1))
    }

    @Test("A large attempt number does not overflow")
    func largeAttemptsAreSafe() {
        // Shifting by the attempt count would trap long before this.
        #expect(policy.delay(forAttempt: 1000, randomFraction: 1) == .seconds(30))
    }

    @Test("Attempts stop at the limit")
    func attemptsAreBounded() {
        #expect(policy.allowsAttempt(8))
        #expect(!policy.allowsAttempt(9))
        #expect(ReconnectionPolicy(maxAttempts: nil).allowsAttempt(10_000))
    }

    @Test("Only failures a retry can actually fix are retried")
    func retryableCategories() {
        #expect(ReconnectionPolicy.isWorthRetrying(.network))
        #expect(ReconnectionPolicy.isWorthRetrying(.tunnel))
    }

    @Test("Security checks are never retried past")
    func securityFailuresAreNotRetried() {
        // A user who sees a host-key warning clear itself on a retry learns to ignore it.
        #expect(!ReconnectionPolicy.isWorthRetrying(.hostKey))
        #expect(!ReconnectionPolicy.isWorthRetrying(.tls))
        #expect(!ReconnectionPolicy.isWorthRetrying(.sshTransport))
    }

    @Test("Credentials are never resent automatically")
    func credentialFailuresAreNotRetried() {
        // Repeating a rejected password is how an account gets locked out.
        #expect(!ReconnectionPolicy.isWorthRetrying(.sshAuthentication))
        #expect(!ReconnectionPolicy.isWorthRetrying(.access))
        #expect(!ReconnectionPolicy.isWorthRetrying(.credential))
    }

    @Test("Every category has a considered answer")
    func everyCategoryIsCovered() {
        // A new category must be thought about rather than defaulting to "retry".
        for category in STErrorCategory.allCases {
            let retries = ReconnectionPolicy.isWorthRetrying(category)
            #expect(retries == [.network, .tunnel].contains(category), "\(category) is unclassified")
        }
    }
}
