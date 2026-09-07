import Foundation

/// Fails rather than hangs when something under test never produces a result.
///
/// A test that waits forever is worse than a failing one: it hides which change broke
/// what, and it blocks the whole suite. Every await on remote output goes through this.
///
/// `body` **must** be cancellable — iterating an `AsyncStream` is; awaiting another
/// `Task`'s `value` or a NIO `EventLoopFuture.get()` is not. A non-cancellable body
/// turns the timeout itself into a hang, because the task group cannot drain until
/// every child finishes.
public func withTimeout<T: Sendable>(
    seconds: Double,
    _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TestTimeoutError(seconds: seconds)
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw TestTimeoutError(seconds: seconds) }
        return first
    }
}

public struct TestTimeoutError: Error, CustomStringConvertible, Sendable {
    public let seconds: Double
    public var description: String { "timed out after \(seconds)s" }
}
