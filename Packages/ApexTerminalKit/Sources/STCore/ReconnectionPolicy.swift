import Foundation

/// When to try a connection again, and how long to wait first.
///
/// Pure logic with no clock and no randomness of its own, so the decisions it makes can
/// be tested exactly rather than observed to be roughly right.
///
/// The hard part of automatic reconnection is not the backoff, it is knowing which
/// failures may be retried at all. Retrying the wrong one is worse than not retrying:
/// repeating a rejected password locks the account out, and quietly retrying past a
/// changed host key or a failed certificate check turns a security signal into something
/// the user learns to read as flakiness.
public struct ReconnectionPolicy: Sendable, Equatable {
    /// The wait before the first retry. Doubles from there.
    public var baseDelay: Duration
    /// The ceiling. A phone that has been in a tunnel for ten minutes should still be
    /// trying every half minute, not once an hour.
    public var maxDelay: Duration
    /// How many times to try before giving up and waiting for the user. `nil` keeps
    /// trying, which is right only while something else — the network coming back — can
    /// change the answer.
    public var maxAttempts: Int?

    public init(
        baseDelay: Duration = .seconds(1),
        maxDelay: Duration = .seconds(30),
        maxAttempts: Int? = 8
    ) {
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.maxAttempts = maxAttempts
    }

    /// The wait before `attempt`, which is 1 for the first retry.
    ///
    /// Exponential with equal jitter: half the computed delay, plus a random share of the
    /// other half. Full jitter would spread load better but makes the countdown shown to
    /// the user jump about, and a person watching "reconnecting in 4s" wants it to mean
    /// something. `randomFraction` is supplied rather than drawn here so a test can pin it.
    public func delay(forAttempt attempt: Int, randomFraction: Double = Double.random(in: 0 ... 1)) -> Duration {
        precondition(attempt >= 1, "attempts are numbered from one")
        let fraction = min(max(randomFraction, 0), 1)
        let exponent = min(attempt - 1, 32)
        let uncapped = baseDelay * (1 << exponent)
        let capped = min(uncapped, maxDelay)
        let half = capped / 2
        return half + half * fraction
    }

    /// Whether another attempt is allowed at all.
    public func allowsAttempt(_ attempt: Int) -> Bool {
        guard let maxAttempts else { return true }
        return attempt <= maxAttempts
    }

    /// Whether a failure of this kind is worth retrying without asking the user.
    ///
    /// Deliberately a short list. Anything not named here needs a person: either because
    /// retrying cannot help, or because retrying would paper over something they should
    /// see.
    public static func isWorthRetrying(_ category: STErrorCategory) -> Bool {
        switch category {
        case .network:
            // The common case on a phone: Wi-Fi to cellular, a tunnel, a lift, sleep.
            true
        case .tunnel:
            // Cloudflare reached the edge but not the origin. Usually a service that is
            // restarting, and it comes back on its own.
            true
        case .tls, .hostKey:
            // Both are the checks that make the connection worth anything. A user who
            // sees them fail and then succeed on a retry learns to ignore them.
            false
        case .access, .sshAuthentication, .credential:
            // Credentials do not become correct by being sent again, and repeating them
            // is how an account gets locked out or an Access policy starts rate-limiting.
            false
        case .sshTransport:
            // Key exchange or MAC failure. It may be a coincidence; it may be someone
            // interfering. Not something to retry silently.
            false
        case .sshChannel:
            // The server refused a PTY or a shell. Trying again asks the same question.
            false
        case .configuration:
            // A hostname that does not resolve or a port that is wrong stays wrong.
            false
        case .cancelled, .internalError:
            false
        }
    }
}
