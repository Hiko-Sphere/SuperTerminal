import Foundation
import STCore
import STSFTP
import STSSH

/// A live SFTP browsing session over one host's SSH connection (D-042).
///
/// Owns the listing, the navigation, and the transfer queue. Transfers run one at a time
/// on purpose: SFTP shares a single SSH channel, and several large transfers interleaved
/// over it are slower in total than the same transfers in sequence, while making progress
/// for each of them meaningless.
@MainActor
@Observable
final class SFTPSession {
    enum Phase: Equatable {
        case connecting(step: String)
        case ready
        case failed(STError)
    }

    private(set) var phase: Phase = .connecting(step: String(localized: "Connecting"))
    private(set) var path: String = "/"
    private(set) var entries: [SFTPEntry] = []
    private(set) var isLoading = false
    private(set) var transfers: [FileTransfer] = []
    private(set) var operationError: STError?
    /// A decision only the user can make — an unknown host key, a password, a key
    /// passphrase — raised while the connection waits (D-043). Until this existed, a
    /// connection needing one was refused outright rather than asked.
    private(set) var pendingPrompt: TerminalSession.PendingPrompt?

    var showsHiddenFiles = false { didSet { rebuild() } }
    var sort: SFTPEntry.Sort = .name { didSet { rebuild() } }
    var sortAscending = true { didSet { rebuild() } }
    var search = "" { didSet { rebuild() } }

    /// Everything the server returned, before the hidden-file switch and the search box.
    private var allEntries: [SFTPEntry] = []
    private var client: SFTPClient?
    private var connection: SSHConnection?
    /// Hands the transport back rather than closing it (D-054).
    private var releaseConnection: (@Sendable () async -> Void)?
    private let connector: HostConnector
    private let prompts: PromptCoordinator
    private let log: STLogger
    private var transferTask: Task<Void, Never>?

    let hostName: String

    init(hostName: String, connector: HostConnector, prompts: PromptCoordinator, log: STLogger) {
        self.hostName = hostName
        self.connector = connector
        self.prompts = prompts
        self.log = log.child(subsystem: "files")
        // Prompts are raised from the connection's own task, which is not on the main
        // actor; routing them through here is what lets a sheet appear while the
        // connection stays suspended waiting for the answer.
        Task { [weak self, prompts] in
            await prompts.setPromptHandler { prompt in
                Task { @MainActor in self?.pendingPrompt = prompt }
            }
        }
    }

    /// Hands the answer back to the waiting connection.
    func resolvePrompt(_ decision: PromptCoordinator.Decision) {
        let prompts = self.prompts
        Task { await prompts.resolve(decision) }
        pendingPrompt = nil
        phase = .connecting(step: String(localized: "Continuing"))
    }

    // MARK: - Lifecycle

    func connect() async {
        guard client == nil else { return }
        do {
            let established = try await connector.establish { [weak self] step in
                self?.phase = .connecting(step: step)
            }
            let connection = established.connection
            self.connection = connection
            releaseConnection = established.release
            phase = .connecting(step: String(localized: "Opening files"))
            let client = try await connection.openSFTP()
            self.client = client
            // Starting where the user's shell would start is the only sensible default;
            // version 3 has no "home directory" call, so realpath(".") is how it is asked.
            path = (try? await client.realpath(".")) ?? "/"
            phase = .ready
            await reload()
        } catch let error as STError {
            phase = .failed(error)
        } catch {
            phase = .failed(STError(
                category: .sshChannel,
                message: String(localized: "The files on this server could not be opened."),
                recoverySuggestion: String(localized: "Check that the server allows SFTP, then try again."),
                underlyingDescription: String(describing: error)
            ))
        }
    }

    func disconnect() async {
        transferTask?.cancel()
        for transfer in transfers where !transfer.state.isTerminal { transfer.cancel() }
        await client?.close()
        client = nil
        // The SFTP channel was this session's; the transport may be shared (D-054).
        await releaseConnection?()
        releaseConnection = nil
        connection = nil
    }

    // MARK: - Browsing

    func reload() async {
        guard let client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let names = try await client.listDirectory(path)
            allEntries = names.map {
                SFTPEntry(name: $0.filename, attributes: $0.attributes, path: SFTPEntry.join(path, $0.filename))
            }
            operationError = nil
            rebuild()
        } catch {
            allEntries = []
            entries = []
            operationError = Self.describe(error, doing: String(localized: "list this folder"))
        }
    }

    func open(_ entry: SFTPEntry) async {
        guard entry.isDirectory || entry.isSymbolicLink else { return }
        // A symlink may point at a file, in which case opening it as a directory would
        // fail; asking the server what it resolves to costs one round trip and avoids
        // showing an error the user cannot act on.
        if entry.isSymbolicLink, let client {
            let resolved = try? await client.attributes(of: entry.path, followingLinks: true)
            guard resolved?.isDirectory == true else { return }
        }
        await navigate(to: entry.path)
    }

    func navigate(to newPath: String) async {
        path = newPath
        search = ""
        await reload()
    }

    func goUp() async {
        guard let parent = SFTPEntry.parent(of: path) else { return }
        await navigate(to: parent)
    }

    /// The path split into its components, for a bar that can jump to any ancestor.
    var pathComponents: [(name: String, path: String)] {
        var result: [(String, String)] = [(String(localized: "Root"), "/")]
        var current = ""
        for part in path.split(separator: "/") {
            current += "/" + part
            result.append((String(part), current))
        }
        return result
    }

    private func rebuild() {
        var visible = allEntries
        if !showsHiddenFiles { visible.removeAll { $0.isHidden } }
        if !search.isEmpty {
            visible = visible.filter { $0.name.localizedCaseInsensitiveContains(search) }
        }
        entries = SFTPEntry.sorted(visible, by: sort, ascending: sortAscending)
    }

    // MARK: - Operations

    func makeDirectory(named name: String) async {
        await perform(String(localized: "create that folder")) { client in
            try await client.makeDirectory(SFTPEntry.join(self.path, name), permissions: 0o755)
        }
    }

    func rename(_ entry: SFTPEntry, to name: String) async {
        await perform(String(localized: "rename that")) { client in
            try await client.rename(from: entry.path, to: SFTPEntry.join(self.path, name))
        }
    }

    func move(_ entry: SFTPEntry, toDirectory directory: String) async {
        await perform(String(localized: "move that")) { client in
            try await client.rename(from: entry.path, to: SFTPEntry.join(directory, entry.name))
        }
    }

    func delete(_ entry: SFTPEntry) async {
        await perform(String(localized: "delete that")) { client in
            if entry.isDirectory {
                try await client.removeDirectory(entry.path)
            } else {
                try await client.remove(entry.path)
            }
        }
    }

    func setPermissions(_ mode: UInt32, on entry: SFTPEntry) async {
        await perform(String(localized: "change those permissions")) { client in
            // Only the permission bits are sent: including size or times in a SETSTAT
            // would ask the server to change those too.
            try await client.setAttributes(SFTP.Attributes(permissions: mode), of: entry.path)
        }
    }

    private func perform(_ what: String, _ body: (SFTPClient) async throws -> Void) async {
        guard let client else { return }
        do {
            try await body(client)
            operationError = nil
            await reload()
        } catch {
            operationError = Self.describe(error, doing: what)
        }
    }

    // MARK: - Transfers

    func download(_ entry: SFTPEntry, to destination: URL) {
        let transfer = FileTransfer(
            direction: .download, remotePath: entry.path,
            localURL: destination.appendingPathComponent(entry.name), total: entry.attributes.size
        )
        transfers.append(transfer)
        runQueue()
    }

    func upload(_ source: URL) {
        let size = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? UInt64) ?? nil
        let transfer = FileTransfer(
            direction: .upload,
            remotePath: SFTPEntry.join(path, source.lastPathComponent),
            localURL: source,
            total: size
        )
        transfers.append(transfer)
        runQueue()
    }

    /// Downloads one file to an exact URL and waits for it — what a drag needs, since the
    /// system asks for the bytes and expects them, not a queue entry to watch.
    func fetch(_ entry: SFTPEntry, to url: URL) async throws {
        guard let client else { throw SFTPError.channelClosed }
        let handle = try await client.open(entry.path, flags: [.read])
        defer { Task { try? await client.closeHandle(handle) } }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        var offset: UInt64 = 0
        while let chunk = try await client.read(handle: handle, offset: offset, length: SFTPClient.readChunk) {
            try file.write(contentsOf: Data(chunk))
            offset += UInt64(chunk.count)
        }
    }

    func retry(_ transfer: FileTransfer) {
        transfer.prepareForRetry()
        runQueue()
    }

    func clearFinishedTransfers() {
        transfers.removeAll { $0.state.isTerminal }
    }

    private func runQueue() {
        guard transferTask == nil else { return }
        transferTask = Task { [weak self] in
            while let next = self?.transfers.first(where: { $0.state == .waiting }) {
                await self?.run(next)
            }
            self?.transferTask = nil
        }
    }

    private func run(_ transfer: FileTransfer) async {
        guard let client else { transfer.fail(String(localized: "Not connected.")); return }
        transfer.begin()
        do {
            switch transfer.direction {
            case .download: try await download(transfer, using: client)
            case .upload: try await upload(transfer, using: client)
            }
            if transfer.state == .running { transfer.finish() }
            await reload()
        } catch is CancellationError {
            transfer.cancel()
        } catch {
            transfer.fail(Self.describe(error, doing: String(localized: "transfer that file")).message)
        }
    }

    private func download(_ transfer: FileTransfer, using client: SFTPClient) async throws {
        let handle = try await client.open(transfer.remotePath, flags: [.read])
        defer { Task { try? await client.closeHandle(handle) } }

        // Written to a partial file and moved into place at the end, so an interrupted
        // download never leaves something that looks like the whole file.
        let partial = transfer.localURL.appendingPathExtension("apexpartial")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let file = try FileHandle(forWritingTo: partial)
        defer { try? file.close() }

        var offset: UInt64 = 0
        while let chunk = try await client.read(handle: handle, offset: offset, length: SFTPClient.readChunk) {
            try await waitWhilePaused(transfer)
            guard transfer.state != .cancelled else { throw CancellationError() }
            try file.write(contentsOf: Data(chunk))
            offset += UInt64(chunk.count)
            transfer.advance(to: offset)
        }
        try file.close()
        try? FileManager.default.removeItem(at: transfer.localURL)
        try FileManager.default.moveItem(at: partial, to: transfer.localURL)
    }

    private func upload(_ transfer: FileTransfer, using client: SFTPClient) async throws {
        let data = try Data(contentsOf: transfer.localURL)
        // Uploaded beside the destination and renamed onto it, which version 3's RENAME
        // makes atomic — and which is why the destination is removed first, since that
        // same RENAME refuses to clobber.
        let temporary = transfer.remotePath + ".apexupload"
        let handle = try await client.open(temporary, flags: [.write, .create, .truncate], permissions: 0o644)

        var offset = 0
        while offset < data.count {
            try await waitWhilePaused(transfer)
            guard transfer.state != .cancelled else {
                try? await client.closeHandle(handle)
                try? await client.remove(temporary)
                throw CancellationError()
            }
            let end = min(offset + SFTPClient.readChunk, data.count)
            try await client.write(handle: handle, offset: UInt64(offset), bytes: Array(data[offset ..< end]))
            offset = end
            transfer.advance(to: UInt64(offset))
        }
        try await client.closeHandle(handle)
        try? await client.remove(transfer.remotePath)
        try await client.rename(from: temporary, to: transfer.remotePath)
    }

    private func waitWhilePaused(_ transfer: FileTransfer) async throws {
        while transfer.state == .paused {
            try await Task.sleep(for: .milliseconds(150))
        }
    }

    // MARK: - Errors

    /// Turns a protocol status into a sentence naming what failed and what to do, rather
    /// than a code the user has no way to look up.
    nonisolated static func describe(_ error: Error, doing what: String) -> STError {
        guard let sftp = error as? SFTPError else {
            return STError(
                category: .sshChannel,
                message: String(localized: "Could not \(what)."),
                recoverySuggestion: String(localized: "Check the connection and try again."),
                underlyingDescription: String(describing: error)
            )
        }
        switch sftp.status {
        case .permissionDenied:
            return STError(
                category: .credential,
                message: String(localized: "The server refused: you do not have permission to \(what)."),
                recoverySuggestion: String(localized: "Check the file's owner and permissions, or connect as a user who may.")
            )
        case .noSuchFile:
            return STError(
                category: .configuration,
                message: String(localized: "That file or folder is no longer there."),
                recoverySuggestion: String(localized: "Refresh the folder to see what is.")
            )
        case .failure:
            return STError(
                category: .sshChannel,
                message: String(localized: "The server could not \(what)."),
                recoverySuggestion: String(localized: "A folder must be empty before it can be deleted, and a name must not already be taken.")
            )
        default:
            return STError(
                category: .sshChannel,
                message: String(localized: "Could not \(what)."),
                recoverySuggestion: String(localized: "Check the connection and try again."),
                underlyingDescription: String(describing: sftp)
            )
        }
    }
}
