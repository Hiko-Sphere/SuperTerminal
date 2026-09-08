import Foundation
import STSFTP

/// One upload or download, and what it looks like while it is happening (D-042).
///
/// Progress alone is not enough to wait on: a person needs to know whether a transfer is
/// moving, how fast, and how much longer. The speed is a rolling average rather than an
/// instantaneous rate, because an instantaneous one on a mobile link jitters so much it
/// reads as broken.
@MainActor
@Observable
final class FileTransfer: Identifiable {
    enum Direction: Equatable { case upload, download }

    enum State: Equatable {
        case waiting
        case running
        case paused
        case finished
        case cancelled
        case failed(String)

        var isTerminal: Bool {
            switch self {
            case .finished, .cancelled, .failed: true
            case .waiting, .running, .paused: false
            }
        }
    }

    let id = UUID()
    let direction: Direction
    let remotePath: String
    let localURL: URL
    let name: String

    private(set) var state: State = .waiting
    private(set) var transferred: UInt64 = 0
    private(set) var total: UInt64?
    private(set) var bytesPerSecond: Double?

    /// Samples of (time, bytes), kept only long enough to average over.
    private var samples: [(at: Date, bytes: UInt64)] = []
    private static let window: TimeInterval = 3

    init(direction: Direction, remotePath: String, localURL: URL, total: UInt64?) {
        self.direction = direction
        self.remotePath = remotePath
        self.localURL = localURL
        self.total = total
        name = (remotePath as NSString).lastPathComponent
    }

    var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(transferred) / Double(total))
    }

    /// Seconds left at the current rate, or nil when there is not enough to say. Guessing
    /// is worse than saying nothing: a wrong estimate is what makes people give up.
    var secondsRemaining: TimeInterval? {
        guard let total, let rate = bytesPerSecond, rate > 0, total > transferred else { return nil }
        return Double(total - transferred) / rate
    }

    var formattedProgress: String {
        let done = ByteCountFormatter.string(fromByteCount: Int64(transferred), countStyle: .file)
        guard let total else { return done }
        return "\(done) / \(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file))"
    }

    var formattedRate: String? {
        guard let bytesPerSecond, bytesPerSecond > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }

    func begin() { state = .running; samples = [(Date(), transferred)] }
    func pause() { if state == .running { state = .paused } }
    func resume() { if state == .paused { state = .running; samples = [(Date(), transferred)] } }
    func cancel() { if !state.isTerminal { state = .cancelled } }
    func finish() { state = .finished; bytesPerSecond = nil }
    func fail(_ reason: String) { state = .failed(reason); bytesPerSecond = nil }

    /// Called after every chunk. Keeps the rolling window and recomputes the rate.
    func advance(to bytes: UInt64) {
        transferred = bytes
        let now = Date()
        samples.append((now, bytes))
        samples.removeAll { now.timeIntervalSince($0.at) > Self.window }
        guard let first = samples.first, samples.count > 1 else { return }
        let seconds = now.timeIntervalSince(first.at)
        guard seconds > 0.2 else { return }
        bytesPerSecond = Double(bytes - first.bytes) / seconds
    }

    /// A retry starts from nothing rather than resuming: SFTP has no notion of a partial
    /// upload the server will remember, and pretending otherwise is how half a file ends
    /// up looking whole.
    func prepareForRetry() {
        state = .waiting
        transferred = 0
        bytesPerSecond = nil
        samples = []
    }
}
