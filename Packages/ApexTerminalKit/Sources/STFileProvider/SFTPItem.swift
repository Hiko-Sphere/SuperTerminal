import FileProvider
import Foundation
import STSFTP
import UniformTypeIdentifiers

/// One remote file or folder, as Files sees it.
///
/// `@unchecked Sendable` because every stored property is a `let` of a value type: the
/// object cannot change after it is built, so passing it between tasks is safe. The
/// compiler cannot see that through `NSObject`, which the protocol requires.
public final class SFTPItem: NSObject, NSFileProviderItem, @unchecked Sendable {
    public let itemIdentifier: NSFileProviderItemIdentifier
    public let parentItemIdentifier: NSFileProviderItemIdentifier
    public let filename: String
    /// The absolute remote path. Not part of the protocol; the extension uses it to talk
    /// to the server after the system hands an identifier back.
    public let path: String
    public let isDirectory: Bool

    private let size: UInt64?
    private let modified: Date?
    private let permissions: UInt32?

    public init(
        identifier: NSFileProviderItemIdentifier,
        parent: NSFileProviderItemIdentifier,
        filename: String,
        path: String,
        attributes: SFTP.Attributes
    ) {
        itemIdentifier = identifier
        parentItemIdentifier = parent
        self.filename = filename
        self.path = path
        isDirectory = attributes.isDirectory
        size = attributes.size
        modified = attributes.modified
        permissions = attributes.permissions
    }

    /// The domain's root, which has no attributes of its own on the server.
    public static func root(path: String, name: String) -> SFTPItem {
        SFTPItem(
            identifier: .rootContainer,
            parent: .rootContainer,
            filename: name,
            path: path,
            attributes: SFTP.Attributes(permissions: 0x4000 | 0o755)
        )
    }

    public var contentType: UTType {
        if isDirectory { return .folder }
        let suffix = (filename as NSString).pathExtension
        guard !suffix.isEmpty, let type = UTType(filenameExtension: suffix) else { return .data }
        return type
    }

    public var documentSize: NSNumber? {
        guard !isDirectory, let size else { return nil }
        return NSNumber(value: size)
    }

    public var contentModificationDate: Date? { modified }

    /// What Files may offer to do with this item.
    ///
    /// One set for files and folders, deliberately. `allowsAddingSubItems` and
    /// `allowsWriting` are the same bit, as are `allowsContentEnumerating` and
    /// `allowsReading`, so writing them out separately per kind would only look like a
    /// distinction the platform does not make.
    ///
    /// `allowsTrashing` is left out, and that is the decision worth reading: a server has
    /// no trash. Claiming it would make Files offer "Move to Trash" for a file that would
    /// then have to be deleted outright — an undo the user was promised and cannot have.
    /// Without it, Files says Delete and means it. Reparenting is allowed because SFTP
    /// `rename` moves across directories on one server, which is what a drag between
    /// folders is.
    public var capabilities: NSFileProviderItemCapabilities {
        [.allowsReading, .allowsWriting, .allowsDeleting, .allowsRenaming, .allowsReparenting]
    }

    /// What the system compares to decide whether its copy is stale.
    ///
    /// Content is versioned by size and modification time because that is all SFTP
    /// version 3 offers — there is no etag and no content hash. It is therefore possible
    /// for an edit that preserves both to go unnoticed, which is a limitation of the
    /// protocol rather than a shortcut here; a server with second-granularity timestamps
    /// makes it a one-second window.
    public var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(
            contentVersion: Self.token(size ?? 0, modified),
            metadataVersion: Self.token(UInt64(permissions ?? 0), modified)
        )
    }

    private static func token(_ value: UInt64, _ date: Date?) -> Data {
        Data("\(value)-\(date.map { String(Int64($0.timeIntervalSince1970)) } ?? "0")".utf8)
    }
}
