import FileProvider
import Foundation
import NIOTransportServices
import STCore
import STSSH
import STSecureStore

/// The File Provider extension: an SSH server, in the Files app (D-044).
///
/// Replicated rather than the older non-replicated API, which is what lets the system own
/// the local copy of each file — downloads, evictions and conflict handling included —
/// while this only answers questions about the server and moves bytes.
///
/// The whole class is glue. Every decision worth reviewing lives in ``DomainFileSystem``,
/// ``DomainConnection`` and ``FileProviderErrorMapping``, which can be driven from a test
/// against a real OpenSSH server; an extension class can only be driven by the system.
public final class SFTPFileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    private let group = NIOTSEventLoopGroup(loopCount: 1)
    private let log: STLogger
    /// `nil` when the domain has no published record — the connection was deleted, or
    /// the App Group is unavailable. Every request then fails with a reason the user can
    /// act on rather than a crash.
    private let fileSystem: DomainFileSystem?
    private let unavailable: String?

    public required init(domain: NSFileProviderDomain) {
        // The extension's own log stream, so a failure here is visible in the same
        // place as the app's — an extension that logs nowhere is one nobody can debug.
        let log = STLogger(
            subsystem: "fileprovider",
            sinks: [OSLogSink(subsystem: "dev.apexterminal", category: "fileprovider")]
        )
        self.log = log

        guard let container = SharedContainer.url() else {
            fileSystem = nil
            unavailable = String(localized: "Apex Terminal cannot reach its shared storage.", bundle: .module)
            super.init()
            return
        }
        guard let id = UUID(uuidString: domain.identifier.rawValue),
              let record = try? SharedDomainStore(directory: container).domain(id: id)
        else {
            fileSystem = nil
            unavailable = String(localized: "This server is no longer set up in Apex Terminal.", bundle: .module)
            super.init()
            return
        }

        let teamPrefix = Self.appIdentifierPrefix()
        let connection = DomainConnection(
            domain: record,
            secureStore: KeychainSecureStore(
                accessGroup: teamPrefix.map { SecureStoreServices.sharedAccessGroup(teamPrefix: $0) }
            ),
            // Read-only in effect: the refusing approval delegate never stores a key, so
            // this process can learn which hosts are trusted but never add one.
            knownHosts: FileKnownHostsStore(
                url: SharedContainer.knownHostsURL(in: container),
                log: log
            ),
            group: group,
            userAgent: Self.userAgent,
            log: log
        )
        fileSystem = DomainFileSystem(
            domain: record,
            connection: connection,
            identity: ItemIdentityMap.forDomain(id: id, in: container),
            log: log
        )
        unavailable = nil
        super.init()
    }

    public func invalidate() {
        let fileSystem = fileSystem
        let group = group
        Task {
            await fileSystem?.shutdown()
            try? await group.shutdownGracefully()
        }
    }

    // MARK: - Reading

    public func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let completion = UncheckedBox(completionHandler)
        return run { fileSystem, _ in
            completion.value(try await fileSystem.item(for: identifier), nil)
        } onFailure: { error in
            completion.value(nil, error)
        }
    }

    public func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let completion = UncheckedBox(completionHandler)
        let destination = Self.temporaryURL()
        let log = log
        return run { fileSystem, progress in
            do {
                let item = try await fileSystem.fetchContents(of: itemIdentifier, to: destination, progress: progress)
                completion.value(destination, item, nil)
            } catch {
                // The system takes ownership of the URL only on success, so a failed
                // download has to clean up after itself or the container fills with
                // half-written files.
                try? FileManager.default.removeItem(at: destination)
                log.info("fetch failed", ["error": String(describing: error)])
                throw error
            }
        } onFailure: { error in
            completion.value(nil, nil, error)
        }
    }

    // MARK: - Writing

    public func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let completion = UncheckedBox(completionHandler)
        // Read out of the template here rather than carrying it into the task: the
        // template is the system's object, and nothing promises it survives the call.
        let parent = itemTemplate.parentItemIdentifier
        let filename = itemTemplate.filename
        let isFolder = itemTemplate.contentType == .folder
        let unapplied = Self.unsupportedFields.intersection(fields)
        return run { fileSystem, progress in
            if isFolder {
                let item = try await fileSystem.createDirectory(named: filename, in: parent)
                completion.value(item, unapplied, false, nil)
                return
            }
            let path = DomainFileSystem.join(try await fileSystem.path(for: parent), filename)
            // No contents means a new, empty file — writing nothing is exactly right.
            let source: URL
            let temporary: URL?
            if let url {
                source = url
                temporary = nil
            } else {
                let empty = Self.temporaryURL()
                FileManager.default.createFile(atPath: empty.path, contents: Data())
                source = empty
                temporary = empty
            }
            defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
            let item = try await fileSystem.write(contents: source, to: path, permissions: nil, progress: progress)
            completion.value(item, unapplied, false, nil)
        } onFailure: { error in
            completion.value(nil, [], false, error)
        }
    }

    public func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let completion = UncheckedBox(completionHandler)
        let identifier = item.itemIdentifier
        let newParent = changedFields.contains(.parentItemIdentifier) ? item.parentItemIdentifier : nil
        let newName = changedFields.contains(.filename) ? item.filename : nil
        // Everything the protocol cannot carry is reported back as unapplied rather than
        // silently dropped: the system then stops expecting the server to remember it,
        // instead of retrying forever.
        let unapplied = Self.unsupportedFields.intersection(changedFields)
        return run { fileSystem, progress in
            var current = try await fileSystem.item(for: identifier)
            if newParent != nil || newName != nil {
                current = try await fileSystem.move(identifier, toParent: newParent, newName: newName)
            }
            if changedFields.contains(.contents), let newContents {
                current = try await fileSystem.write(
                    contents: newContents,
                    to: current.path,
                    permissions: nil,
                    progress: progress
                )
            }
            completion.value(current, unapplied, false, nil)
        } onFailure: { error in
            completion.value(nil, [], false, error)
        }
    }

    public func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let completion = UncheckedBox(completionHandler)
        return run { fileSystem, _ in
            try await fileSystem.delete(identifier)
            completion.value(nil)
        } onFailure: { error in
            completion.value(error)
        }
    }

    public func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        guard let fileSystem else {
            throw FileProviderErrorMapping.fileProviderError(
                from: FileProviderFailure.needsTheApp(reason: unavailable ?? "")
            )
        }
        if containerItemIdentifier == .workingSet || containerItemIdentifier == .trashContainer {
            return EmptyWorkingSetEnumerator()
        }
        return SFTPEnumerator(container: containerItemIdentifier, fileSystem: fileSystem, log: log)
    }

    // MARK: - Plumbing

    /// Timestamps, tags and favourites have nowhere to live on an SFTP server.
    private static let unsupportedFields: NSFileProviderItemFields =
        [.lastUsedDate, .tagData, .favoriteRank, .creationDate, .extendedAttributes, .typeAndCreator]

    private func run(
        _ body: @escaping @Sendable (DomainFileSystem, Progress) async throws -> Void,
        onFailure: @escaping @Sendable (Error) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        guard let fileSystem else {
            onFailure(FileProviderErrorMapping.fileProviderError(
                from: FileProviderFailure.needsTheApp(reason: unavailable ?? "")
            ))
            progress.completedUnitCount = 1
            return progress
        }
        let task = Task {
            do {
                try await body(fileSystem, progress)
            } catch {
                onFailure(FileProviderErrorMapping.fileProviderError(from: error))
            }
            progress.completedUnitCount = max(progress.completedUnitCount, progress.totalUnitCount)
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    private static func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    /// The team prefix the Keychain access group is built from, read from the bundle's
    /// own entitlements. Hard-coding a team would break the moment the project is signed
    /// by a different one.
    static func appIdentifierPrefix() -> String? {
        guard let group = (Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String)
            ?? accessGroupFromEntitlements()
        else { return nil }
        return group
    }

    private static func accessGroupFromEntitlements() -> String? {
        // `SecTaskCopyValueForEntitlement` needs a task reference the extension does not
        // readily have, so the prefix is taken from a throwaway Keychain item's own
        // access group — the documented trick, and the only one that works in an
        // extension without hard-coding the team.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "dev.apexterminal.teamprefix.probe",
            kSecAttrService as String: "dev.apexterminal.teamprefix.probe",
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            status = SecItemAdd(query as CFDictionary, &result)
        }
        guard status == errSecSuccess,
              let attributes = result as? [String: Any],
              let group = attributes[kSecAttrAccessGroup as String] as? String,
              let dot = group.firstIndex(of: ".")
        else { return nil }
        return String(group[group.startIndex ... dot])
    }

    static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return "ApexTerminal/\(version) (iOS)"
    }()
}
