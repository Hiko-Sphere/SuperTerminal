import FileProvider
import Foundation
import STCore
import STSFTP

/// The remote file system behind one domain, in the terms the File Provider API uses.
///
/// Everything the extension does goes through here: identifiers in, real SFTP out. It is
/// a separate type from the extension class on purpose — the extension class can only be
/// exercised by the system inside an extension host, while this can be pointed at a real
/// OpenSSH server from a test and driven through every operation.
public actor DomainFileSystem {
    private let domain: SharedDomain
    private let connection: DomainConnection
    private let identity: ItemIdentityMap
    private let log: STLogger

    public init(
        domain: SharedDomain,
        connection: DomainConnection,
        identity: ItemIdentityMap,
        log: STLogger = .disabled
    ) {
        self.domain = domain
        self.connection = connection
        self.identity = identity
        self.log = log.child(subsystem: "files.filesystem")
    }

    public func shutdown() async {
        await connection.shutdown()
    }

    // MARK: - Reading

    public func rootItem() async throws -> SFTPItem {
        SFTPItem.root(path: try await connection.rootPath(), name: domain.displayName)
    }

    public func item(for identifier: NSFileProviderItemIdentifier) async throws -> SFTPItem {
        if identifier == .rootContainer { return try await rootItem() }
        let path = try await path(for: identifier)
        let attributes = try await connection.withClient { try await $0.attributes(of: path) }
        return try await makeItem(path: path, attributes: attributes, identifier: identifier)
    }

    /// The contents of a container, with symbolic links resolved.
    ///
    /// `.` and `..` are dropped: they are directory entries in the protocol, but showing
    /// them would let a user navigate out of the domain's root, which is not a place the
    /// domain can describe.
    public func contents(of container: NSFileProviderItemIdentifier) async throws -> [SFTPItem] {
        let directory = try await path(for: container)
        let names = try await connection.withClient { try await $0.listDirectory(directory) }
        var items: [SFTPItem] = []
        for name in names where name.filename != "." && name.filename != ".." {
            let path = Self.join(directory, name.filename)
            var attributes = name.attributes
            if attributes.isSymbolicLink {
                // What the link points at decides whether Files can open it as a folder.
                // A broken link keeps the link's own attributes rather than disappearing:
                // it exists on the server, and hiding it would be a lie about the listing.
                attributes = (try? await connection.withClient {
                    try await $0.attributes(of: path, followingLinks: true)
                }) ?? attributes
            }
            items.append(try await makeItem(path: path, attributes: attributes, identifier: nil))
        }
        return items
    }

    /// Downloads a file to `destination`, which the caller owns.
    public func fetchContents(
        of identifier: NSFileProviderItemIdentifier,
        to destination: URL,
        progress: Progress
    ) async throws -> SFTPItem {
        let path = try await path(for: identifier)
        let attributes = try await connection.withClient { try await $0.attributes(of: path) }
        guard !attributes.isDirectory else { throw SFTPError.serverRefused(.failure, String(
            localized: "A folder has no contents to download.", bundle: .module
        )) }
        progress.totalUnitCount = Int64(attributes.size ?? 0)

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        try await connection.withClient { client in
            // A retry starts the file again, so the local one has to start again too;
            // otherwise the second attempt appends to the first's partial download.
            try handle.truncate(atOffset: 0)
            progress.completedUnitCount = 0
            let remote = try await client.open(path, flags: .read)
            do {
                var offset: UInt64 = 0
                while true {
                    try Task.checkCancellation()
                    guard let bytes = try await client.read(
                        handle: remote,
                        offset: offset,
                        length: SFTPClient.readChunk
                    ), !bytes.isEmpty else { break }
                    try handle.write(contentsOf: Data(bytes))
                    offset += UInt64(bytes.count)
                    progress.completedUnitCount = Int64(offset)
                }
                try await client.closeHandle(remote)
            } catch {
                try? await client.closeHandle(remote)
                throw error
            }
        }
        return try await makeItem(path: path, attributes: attributes, identifier: identifier)
    }

    // MARK: - Writing

    public func createDirectory(named name: String, in parent: NSFileProviderItemIdentifier) async throws -> SFTPItem {
        let path = Self.join(try await path(for: parent), name)
        try await connection.withClient { try await $0.makeDirectory(path) }
        let attributes = try await connection.withClient { try await $0.attributes(of: path) }
        return try await makeItem(path: path, attributes: attributes, identifier: nil)
    }

    /// Uploads `contents` as a new file, or replaces an existing one.
    ///
    /// The upload goes to a temporary name in the same directory and is renamed into
    /// place only once every byte is written. A connection that drops halfway therefore
    /// leaves the previous file untouched instead of a truncated one — the same
    /// commit-by-rename the app's own transfers use (D-042).
    public func write(
        contents url: URL,
        to path: String,
        permissions: UInt32?,
        progress: Progress
    ) async throws -> SFTPItem {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let total = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64 ?? 0
        progress.totalUnitCount = Int64(total)

        let directory = (path as NSString).deletingLastPathComponent

        // The upload does its own recovery rather than using the connection's blanket
        // retry, because it is not an operation that can simply be run again: each
        // attempt holds a temporary file on the server, and the connection that died is
        // the one that would have had to remove it. So the failure is caught here, the
        // dead attempt's file is removed over the *next* connection, and only then is a
        // second attempt made — with its own name, and reading the local file from the
        // start, since the first attempt left the handle part-way through.
        var lastError: Error?
        for attempt in 0 ..< 2 {
            let temporary = Self.join(directory, ".apexupload-\(UUID().uuidString.prefix(8))")
            do {
                let client = try await connection.liveClient()
                try handle.seek(toOffset: 0)
                progress.completedUnitCount = 0
                let remote = try await client.open(
                    temporary,
                    flags: [.write, .create, .truncate, .exclusive],
                    permissions: permissions
                )
                do {
                    var offset: UInt64 = 0
                    while true {
                        try Task.checkCancellation()
                        let chunk = try handle.read(upToCount: SFTPClient.readChunk) ?? Data()
                        if chunk.isEmpty { break }
                        try await client.write(handle: remote, offset: offset, bytes: [UInt8](chunk))
                        offset += UInt64(chunk.count)
                        progress.completedUnitCount = Int64(offset)
                    }
                    try await client.closeHandle(remote)
                } catch {
                    try? await client.closeHandle(remote)
                    throw error
                }
                // Version 3 leaves it to the server whether a rename may replace an
                // existing file, and OpenSSH refuses. Removing the old name first is what
                // makes an overwrite work at all; the window it opens is the same one
                // `mv` has.
                try? await client.remove(path)
                try await client.rename(from: temporary, to: path)
                lastError = nil
                break
            } catch {
                lastError = error
                let dropped = DomainConnection.isDropped(error)
                if dropped { await connection.disconnect() }
                // Either way the attempt's temporary has to go. Over a live connection it
                // works immediately; over a dead one this reconnects first, which is
                // exactly what the next attempt needs anyway.
                try? await connection.withClient { try await $0.remove(temporary) }
                guard dropped, attempt == 0 else { throw error }
                log.info("retrying an upload after the connection dropped")
            }
        }
        if let lastError { throw lastError }

        let attributes = try await connection.withClient { try await $0.attributes(of: path) }
        return try await makeItem(path: path, attributes: attributes, identifier: nil)
    }

    public func delete(_ identifier: NSFileProviderItemIdentifier) async throws {
        let path = try await path(for: identifier)
        let attributes = try await connection.withClient { try await $0.attributes(of: path, followingLinks: false) }
        try await connection.withClient { client in
            if attributes.isDirectory {
                try await client.removeDirectory(path)
            } else {
                try await client.remove(path)
            }
        }
        await identity.forget(path)
    }

    /// Renames, moves, or both — one SFTP `rename` either way.
    public func move(
        _ identifier: NSFileProviderItemIdentifier,
        toParent parent: NSFileProviderItemIdentifier?,
        newName: String?
    ) async throws -> SFTPItem {
        let path = try await path(for: identifier)
        let directory: String
        if let parent {
            directory = try await self.path(for: parent)
        } else {
            directory = (path as NSString).deletingLastPathComponent
        }
        let name = newName ?? (path as NSString).lastPathComponent
        let destination = Self.join(directory, name)
        guard destination != path else { return try await item(for: identifier) }
        try await connection.withClient { try await $0.rename(from: path, to: destination) }
        await identity.move(from: path, to: destination)
        let attributes = try await connection.withClient { try await $0.attributes(of: destination) }
        return try await makeItem(path: destination, attributes: attributes, identifier: identifier)
    }

    /// The remote path an identifier stands for.
    public func path(for identifier: NSFileProviderItemIdentifier) async throws -> String {
        if identifier == .rootContainer { return try await connection.rootPath() }
        guard let path = await identity.path(for: identifier.rawValue) else {
            // The system is asking about something this device has never enumerated —
            // after the identity map was lost, or for an item another device created.
            // `noSuchItem` is the honest answer: re-enumeration will hand it back with a
            // fresh identifier.
            throw NSError(
                domain: NSFileProviderErrorDomain,
                code: NSFileProviderError.noSuchItem.rawValue
            )
        }
        return path
    }

    // MARK: - Helpers

    private func makeItem(
        path: String,
        attributes: SFTP.Attributes,
        identifier: NSFileProviderItemIdentifier?
    ) async throws -> SFTPItem {
        let root = try await connection.rootPath()
        let resolved: NSFileProviderItemIdentifier
        if let identifier {
            resolved = identifier
        } else {
            resolved = NSFileProviderItemIdentifier(await identity.identifier(forPath: path))
        }
        let parentPath = (path as NSString).deletingLastPathComponent
        let parent: NSFileProviderItemIdentifier
        if path == root || parentPath == root {
            parent = .rootContainer
        } else {
            parent = NSFileProviderItemIdentifier(await identity.identifier(forPath: parentPath))
        }
        return SFTPItem(
            identifier: resolved,
            parent: parent,
            filename: (path as NSString).lastPathComponent,
            path: path,
            attributes: attributes
        )
    }

    static func join(_ directory: String, _ name: String) -> String {
        if directory.isEmpty || directory == "/" { return "/" + name }
        return directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }
}
