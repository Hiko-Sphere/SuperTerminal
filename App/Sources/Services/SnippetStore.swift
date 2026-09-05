import Foundation
import Observation
import STCore

/// Stores snippets and, if the user has switched it on, command history.
///
/// History is off by default and this type enforces that: ``record(command:)`` checks the
/// setting on every call rather than trusting a caller to have checked. A terminal's
/// history is among the most sensitive things a device can hold — it contains hostnames,
/// paths, and often enough context to reconstruct what someone was doing — so the
/// expensive check is worth making in the one place it cannot be forgotten.
@Observable
@MainActor
final class SnippetStore {
    private(set) var snippets: [Snippet] = []
    /// See `HostStore.tombstones`.
    var tombstones: SyncTombstones?
    private(set) var history: [HistoryEntry] = []
    private(set) var loadError: STError?

    /// History older than this is discarded. A bounded window means switching the feature
    /// on does not create an unbounded record of everything, ever.
    static let historyLimit = 500

    private let snippetsURL: URL
    private let historyURL: URL
    private let settings: AppSettings

    init(directory: URL, settings: AppSettings) {
        snippetsURL = directory.appendingPathComponent("snippets.json")
        historyURL = directory.appendingPathComponent("history.json")
        self.settings = settings
        load()
    }

    // MARK: - Snippets

    func add(_ snippet: Snippet, stamping: Bool = true) {
        var snippet = snippet
        if stamping { snippet.modifiedAt = Date() }
        snippets.append(snippet)
        sortSnippets()
        persistSnippets()
    }

    func update(_ snippet: Snippet, stamping: Bool = true) {
        guard let index = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        var snippet = snippet
        if stamping { snippet.modifiedAt = Date() }
        snippets[index] = snippet
        sortSnippets()
        persistSnippets()
    }

    func remove(_ snippet: Snippet, recordingTombstone: Bool = true) {
        snippets.removeAll { $0.id == snippet.id }
        if recordingTombstone { tombstones?.record(SyncKey(kind: .snippet, id: snippet.id.uuidString)) }
        persistSnippets()
    }

    /// Records that a snippet was used, so the list can surface the useful ones.
    func markUsed(_ snippet: Snippet) {
        guard let index = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        snippets[index].useCount += 1
        snippets[index].lastUsed = Date()
        sortSnippets()
        persistSnippets()
    }

    var folders: [String] {
        Array(Set(snippets.compactMap(\.folder))).sorted()
    }

    /// Adds the starter set, skipping any whose command is already saved.
    func installStarterSet() {
        let existing = Set(snippets.map(\.command))
        for snippet in Snippet.starterSet where !existing.contains(snippet.command) {
            snippets.append(snippet)
        }
        sortSnippets()
        persistSnippets()
    }

    // MARK: - History

    /// Records a command, if history is enabled.
    ///
    /// Silently does nothing when the setting is off. That is the point: the check lives
    /// here so no call site can bypass it.
    func record(command: String, hostID: UUID, hostName: String) {
        guard settings.commandHistoryEnabled else { return }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Consecutive repeats add nothing and push older, more useful entries out.
        if history.last?.command == trimmed, history.last?.hostID == hostID { return }

        history.append(HistoryEntry(command: trimmed, hostID: hostID, hostName: hostName))
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
        persistHistory()
    }

    func searchHistory(_ query: String, hostID: UUID? = nil) -> [HistoryEntry] {
        var results = history
        if let hostID { results = results.filter { $0.hostID == hostID } }
        if !query.isEmpty {
            let needle = query.lowercased()
            results = results.filter { $0.command.lowercased().contains(needle) }
        }
        return results.reversed()
    }

    /// Deletes everything recorded. Called when the user turns the feature off, so
    /// switching it off actually means something.
    func clearHistory() {
        history = []
        try? FileManager.default.removeItem(at: historyURL)
    }

    func removeAll() {
        snippets = []
        history = []
        persistSnippets()
        clearHistory()
    }

    // MARK: - Persistence

    private func sortSnippets() {
        // Most-used first, then alphabetical. A list ordered by creation date puts the
        // least familiar things at the top.
        snippets.sort {
            if $0.useCount != $1.useCount { return $0.useCount > $1.useCount }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            if FileManager.default.fileExists(atPath: snippetsURL.path) {
                snippets = try decoder.decode([Snippet].self, from: Data(contentsOf: snippetsURL))
            }
            // History is only read back when the feature is on. Leaving a file behind that
            // is silently reloaded if someone re-enables the setting would defeat the
            // point of turning it off.
            if settings.commandHistoryEnabled, FileManager.default.fileExists(atPath: historyURL.path) {
                history = try decoder.decode([HistoryEntry].self, from: Data(contentsOf: historyURL))
            }
        } catch {
            loadError = STError(
                category: .internalError,
                message: String(localized: "Your snippets could not be read."),
                recoverySuggestion: String(localized: "Your data has been left untouched."),
                underlyingDescription: String(describing: error)
            )
        }
    }

    /// Fired after a snippet change. History is not synced and does not fire it.
    var didChange: (() -> Void)?

    private func persistSnippets() { persist(snippets, to: snippetsURL); didChange?() }

    private func persistHistory() {
        persist(history, to: historyURL)
        // Snippets are things a person wrote and would want back on a new device.
        // History is a record of what they did, and should not follow them around.
        var url = historyURL
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? url.setResourceValues(resourceValues)
    }

    private func persist(_ value: some Encodable, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(value).write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            loadError = STError(
                category: .internalError,
                message: String(localized: "Changes could not be saved."),
                underlyingDescription: String(describing: error)
            )
        }
    }
}
