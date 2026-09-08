import FileProvider
import Foundation
import STCore

/// Enumerates one remote folder, and works out what changed since the last look.
///
/// SFTP has no change notification: nothing on the server can tell the device that a file
/// appeared. So "what changed" is answered the only way the protocol allows — by listing
/// the folder again and comparing it with the previous listing. That is a real
/// comparison, not a claim that nothing changed, and it is why a pull-to-refresh in Files
/// costs one `READDIR` and shows the truth.
///
/// The consequence is stated plainly in the documentation: a change made on the server is
/// noticed when the folder is opened or refreshed, not the moment it happens. Anything
/// else would need a channel the protocol does not have.
public final class SFTPEnumerator: NSObject, NSFileProviderEnumerator {
    private let container: NSFileProviderItemIdentifier
    private let fileSystem: DomainFileSystem
    private let state = EnumerationState()
    private let log: STLogger
    private var work: Task<Void, Never>?

    public init(container: NSFileProviderItemIdentifier, fileSystem: DomainFileSystem, log: STLogger = .disabled) {
        self.container = container
        self.fileSystem = fileSystem
        self.log = log.child(subsystem: "files.enumerator")
    }

    public func invalidate() {
        work?.cancel()
        work = nil
    }

    public func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let observer = UncheckedBox(observer)
        work = Task { [container, fileSystem, state, log] in
            do {
                let items = try await fileSystem.contents(of: container)
                await state.replace(with: items)
                // Emitted in batches so a folder with thousands of entries starts
                // appearing before the last one is described.
                for batch in stride(from: 0, to: items.count, by: 200) {
                    observer.value.didEnumerate(Array(items[batch ..< min(batch + 200, items.count)]))
                }
                observer.value.finishEnumerating(upTo: nil)
            } catch {
                log.info("enumeration failed", ["error": String(describing: error)])
                observer.value.finishEnumeratingWithError(FileProviderErrorMapping.fileProviderError(from: error))
            }
        }
    }

    public func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let completion = UncheckedBox(completionHandler)
        Task { [state] in
            completion.value(await state.anchor)
        }
    }

    public func enumerateChanges(for observer: NSFileProviderChangeObserver, from syncAnchor: NSFileProviderSyncAnchor) {
        let observer = UncheckedBox(observer)
        work = Task { [container, fileSystem, state, log] in
            guard await state.matches(syncAnchor) else {
                // The listing this anchor described is gone — a new process, or an
                // enumeration that has since moved on. Expiring the anchor is the
                // documented way to ask the system for a full re-enumeration, and it is
                // honest: the changes since then genuinely cannot be reconstructed.
                observer.value.finishEnumeratingWithError(NSError(
                    domain: NSFileProviderErrorDomain,
                    code: NSFileProviderError.syncAnchorExpired.rawValue
                ))
                return
            }
            do {
                let items = try await fileSystem.contents(of: container)
                let change = await state.apply(items)
                if !change.updated.isEmpty { observer.value.didUpdate(change.updated) }
                if !change.deleted.isEmpty { observer.value.didDeleteItems(withIdentifiers: change.deleted) }
                observer.value.finishEnumeratingChanges(upTo: change.anchor, moreComing: false)
            } catch {
                log.info("change enumeration failed", ["error": String(describing: error)])
                observer.value.finishEnumeratingWithError(FileProviderErrorMapping.fileProviderError(from: error))
            }
        }
    }
}

/// The previous listing, and the anchor that names it.
private actor EnumerationState {
    private var items: [NSFileProviderItemIdentifier: SFTPItem] = [:]
    private var counter: UInt64 = 0
    private var started = false

    var anchor: NSFileProviderSyncAnchor? {
        // No anchor before the first listing: the system then enumerates items rather
        // than asking for changes it has no baseline for.
        started ? NSFileProviderSyncAnchor(Data("\(counter)".utf8)) : nil
    }

    func matches(_ candidate: NSFileProviderSyncAnchor) -> Bool {
        started && candidate.rawValue == Data("\(counter)".utf8)
    }

    func replace(with new: [SFTPItem]) {
        items = Dictionary(new.map { ($0.itemIdentifier, $0) }, uniquingKeysWith: { _, latest in latest })
        started = true
        counter += 1
    }

    struct Change: Sendable {
        var updated: [SFTPItem]
        var deleted: [NSFileProviderItemIdentifier]
        var anchor: NSFileProviderSyncAnchor
    }

    func apply(_ new: [SFTPItem]) -> Change {
        let fresh = Dictionary(new.map { ($0.itemIdentifier, $0) }, uniquingKeysWith: { _, latest in latest })
        var updated: [SFTPItem] = []
        for (identifier, item) in fresh {
            guard let previous = items[identifier] else { updated.append(item); continue }
            if previous.itemVersion.contentVersion != item.itemVersion.contentVersion
                || previous.itemVersion.metadataVersion != item.itemVersion.metadataVersion
                || previous.filename != item.filename {
                updated.append(item)
            }
        }
        let deleted = items.keys.filter { fresh[$0] == nil }
        items = fresh
        started = true
        counter += 1
        return Change(updated: updated, deleted: Array(deleted), anchor: NSFileProviderSyncAnchor(Data("\(counter)".utf8)))
    }
}

/// The working set, which this provider keeps empty.
///
/// The working set is the list of items a provider wants kept fresh without being asked —
/// the ones that show up in Recents and in offline search. Keeping it fresh means knowing
/// when they change, and SFTP cannot say. Rather than enumerate items into a set whose
/// contract is "these are up to date", the set is left empty and every folder is refreshed
/// when it is looked at. Files still opens, edits and saves normally; what is given up is
/// a file appearing in Recents while nobody is looking at its folder.
public final class EmptyWorkingSetEnumerator: NSObject, NSFileProviderEnumerator {
    public override init() {}
    public func invalidate() {}

    public func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        observer.finishEnumerating(upTo: nil)
    }

    public func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(Data("empty".utf8)))
    }

    public func enumerateChanges(for observer: NSFileProviderChangeObserver, from syncAnchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(Data("empty".utf8)), moreComing: false)
    }
}
