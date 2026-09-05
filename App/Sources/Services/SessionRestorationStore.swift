import Foundation
import Observation
import STCore

/// Remembers which connections were open, so they can be reopened after a relaunch.
///
/// Reopened, not restored, and the difference is the whole design. A live SSH session
/// cannot survive the process dying: the socket is gone, the shell is gone, and anything
/// that was running went with it. What can be carried across is the *intent* — these are
/// the machines you were working on — and offering that honestly is worth a great deal on
/// a phone, which kills backgrounded apps as a matter of routine.
///
/// The scrollback is deliberately **not** kept. It is the same asset as command history —
/// it holds every command and everything the server printed back — but far larger and
/// with no bound that means anything. The app refuses to write history to disk unless
/// asked; writing the whole buffer instead would make that refusal meaningless.
@Observable
@MainActor
final class SessionRestorationStore {
    /// Connections that were open when the app last stopped.
    private(set) var pending: [RestorableSession] = []

    struct RestorableSession: Codable, Identifiable, Equatable, Sendable {
        var id: UUID
        var hostID: UUID
        var hostName: String
        var endedAt: Date
    }

    /// Older than this and it is no longer "where you left off", it is history.
    static let maximumAge: TimeInterval = 60 * 60 * 24 * 7

    private let url: URL

    init(directory: URL) {
        url = directory.appendingPathComponent("open_sessions.json")
        load()
    }

    /// Records what is open now. Called whenever the set of sessions changes.
    func record(hosts: [(id: UUID, name: String)]) {
        let now = Date()
        let entries = hosts.map {
            RestorableSession(id: UUID(), hostID: $0.id, hostName: $0.name, endedAt: now)
        }
        persist(entries)
    }

    /// Forgets everything, once the user has acted on it or dismissed it.
    func clear() {
        pending = []
        try? FileManager.default.removeItem(at: url)
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let stored = try? decoder.decode([RestorableSession].self, from: data)
        else { return }
        // A week-old list is not "where you left off"; offering it would be noise.
        pending = stored.filter { Date().timeIntervalSince($0.endedAt) < Self.maximumAge }
    }

    private func persist(_ entries: [RestorableSession]) {
        // `pending` is what was open *last* time; writing what is open now must not
        // change what the user is currently being offered.
        guard !entries.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        // Which machines someone works on is not secret, but it is not nothing either:
        // it names internal hosts. Same protection as the connection list itself.
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }
}
