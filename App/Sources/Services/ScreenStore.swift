import Foundation
import Observation
import STCore

/// The saved remote screens (D-027).
///
/// A screen is its own connection, kept in its own file for the same reason the host list
/// is: it is non-secret metadata, and the VNC password it refers to is in the Keychain.
/// Keeping the split explicit is what makes a screen safe to sync.
@Observable
@MainActor
final class ScreenStore {
    private(set) var screens: [ScreenConnection] = []
    /// Where deletions are remembered for sync. Set by the container.
    var tombstones: SyncTombstones?
    private(set) var loadError: STError?
    /// Fired after any change, so sync can follow edits without polling.
    var didChange: (() -> Void)?

    private let url: URL

    init(directory: URL) {
        url = directory.appendingPathComponent("screens.json")
        load()
    }

    /// `stamping` is false only when the record arrived from another device and already
    /// carries the time it changed there; stamping it again would make this device the
    /// newer writer and echo it straight back.
    func add(_ screen: ScreenConnection, stamping: Bool = true) {
        var screen = screen
        if stamping { screen.modifiedAt = Date() }
        screens.append(screen)
        sort()
        persist()
    }

    func update(_ screen: ScreenConnection, stamping: Bool = true) {
        guard let index = screens.firstIndex(where: { $0.id == screen.id }) else { return }
        var screen = screen
        if stamping { screen.modifiedAt = Date() }
        screens[index] = screen
        sort()
        persist()
    }

    /// Inserts a screen only if one with that id is not already there.
    ///
    /// Migration uses it: two devices deriving the same screen from the same connection
    /// must converge on one record, and whichever gets there second must not overwrite an
    /// edit the user has since made.
    @discardableResult
    func insertIfAbsent(_ screen: ScreenConnection, stamping: Bool = true) -> Bool {
        guard !screens.contains(where: { $0.id == screen.id }) else { return false }
        add(screen, stamping: stamping)
        return true
    }

    func remove(_ screen: ScreenConnection, recordingTombstone: Bool = true) {
        screens.removeAll { $0.id == screen.id }
        if recordingTombstone {
            tombstones?.record(SyncKey(kind: .screen, id: screen.id.uuidString))
        }
        persist()
    }

    func markConnected(_ screen: ScreenConnection, at date: Date = Date()) {
        guard let index = screens.firstIndex(where: { $0.id == screen.id }) else { return }
        // Not stamped: when a screen was last opened is this device's business, and
        // stamping it would make every connection a change other devices must fetch.
        screens[index].lastConnected = date
        persist()
    }

    func screen(withID id: UUID) -> ScreenConnection? {
        screens.first { $0.id == id }
    }

    /// The screens that go through a given SSH connection, so deleting it can say what
    /// else it affects.
    func screens(throughHostID id: UUID) -> [ScreenConnection] {
        screens.filter { $0.route.sshHostID == id }
    }

    func removeAll() {
        screens = []
        persist()
    }

    private func sort() {
        screens.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            screens = try decoder.decode([ScreenConnection].self, from: Data(contentsOf: url))
        } catch {
            // A corrupt file must not silently wipe the user's screens, so the existing
            // file is left alone and the problem is surfaced instead.
            loadError = STError(
                category: .internalError,
                message: String(localized: "Your saved screens could not be read."),
                recoverySuggestion: String(localized: "Your data has been left untouched. Reinstalling will clear it if you want to start over."),
                underlyingDescription: String(describing: error)
            )
        }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(screens)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            loadError = STError(
                category: .internalError,
                message: String(localized: "Your saved screens could not be written."),
                underlyingDescription: String(describing: error)
            )
        }
        didChange?()
    }
}
