import Foundation
import NIOCore

/// The SFTP wire format, version 3 (D-041).
///
/// Version 3 is `draft-ietf-secsh-filexfer-02`, and it is what OpenSSH's server speaks —
/// later drafts exist but no widely deployed server implements them, so a client that
/// insisted on one would talk to nothing. Every field below is from that draft; nothing
/// here is inferred from another client's behaviour.
public enum SFTP {
    /// Packet types. Requests are below 100, responses at 101 and above.
    public enum PacketType: UInt8, Sendable {
        case initialise = 1, version = 2
        case open = 3, close = 4, read = 5, write = 6
        case lstat = 7, fstat = 8, setstat = 9, fsetstat = 10
        case opendir = 11, readdir = 12
        case remove = 13, mkdir = 14, rmdir = 15, realpath = 16
        case stat = 17, rename = 18, readlink = 19, symlink = 20
        case status = 101, handle = 102, data = 103, name = 104, attrs = 105
    }

    /// The status codes a server may answer with. `eof` is not an error: it is how a
    /// directory listing and a read past the end both end.
    public enum Status: UInt32, Sendable {
        case ok = 0, eof = 1, noSuchFile = 2, permissionDenied = 3
        case failure = 4, badMessage = 5, noConnection = 6, connectionLost = 7
        case operationUnsupported = 8
    }

    /// Flags for `open`. Version 3 spells them out rather than using POSIX values.
    public struct OpenFlags: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let read = OpenFlags(rawValue: 0x0000_0001)
        public static let write = OpenFlags(rawValue: 0x0000_0002)
        public static let append = OpenFlags(rawValue: 0x0000_0004)
        public static let create = OpenFlags(rawValue: 0x0000_0008)
        public static let truncate = OpenFlags(rawValue: 0x0000_0010)
        /// Fails if the file exists — the half of an atomic create that makes it atomic.
        public static let exclusive = OpenFlags(rawValue: 0x0000_0020)
    }

    /// A file's attributes. Every field is optional on the wire, announced by a flag word,
    /// so a server that knows nothing about a file still sends a valid ATTRS.
    public struct Attributes: Sendable, Equatable {
        public var size: UInt64?
        public var uid: UInt32?
        public var gid: UInt32?
        public var permissions: UInt32?
        public var accessed: Date?
        public var modified: Date?

        public init(
            size: UInt64? = nil, uid: UInt32? = nil, gid: UInt32? = nil,
            permissions: UInt32? = nil, accessed: Date? = nil, modified: Date? = nil
        ) {
            self.size = size
            self.uid = uid
            self.gid = gid
            self.permissions = permissions
            self.accessed = accessed
            self.modified = modified
        }

        static let flagSize: UInt32 = 0x0000_0001
        static let flagUIDGID: UInt32 = 0x0000_0002
        static let flagPermissions: UInt32 = 0x0000_0004
        static let flagTimes: UInt32 = 0x0000_0008
        static let flagExtended: UInt32 = 0x8000_0000

        /// The POSIX file type bits, which is how a listing tells a directory from a file
        /// without a second round trip.
        public var isDirectory: Bool { (permissions ?? 0) & 0xF000 == 0x4000 }
        public var isSymbolicLink: Bool { (permissions ?? 0) & 0xF000 == 0xA000 }
        public var isRegularFile: Bool { (permissions ?? 0) & 0xF000 == 0x8000 }

        public func write(into buffer: inout ByteBuffer) {
            var flags: UInt32 = 0
            if size != nil { flags |= Self.flagSize }
            if uid != nil, gid != nil { flags |= Self.flagUIDGID }
            if permissions != nil { flags |= Self.flagPermissions }
            if accessed != nil, modified != nil { flags |= Self.flagTimes }
            buffer.writeInteger(flags)
            if let size { buffer.writeInteger(size) }
            if let uid, let gid { buffer.writeInteger(uid); buffer.writeInteger(gid) }
            if let permissions { buffer.writeInteger(permissions) }
            if let accessed, let modified {
                buffer.writeInteger(UInt32(accessed.timeIntervalSince1970))
                buffer.writeInteger(UInt32(modified.timeIntervalSince1970))
            }
        }

        public static func read(from buffer: inout ByteBuffer) -> Attributes? {
            guard let flags: UInt32 = buffer.readInteger() else { return nil }
            var attributes = Attributes()
            if flags & flagSize != 0 {
                guard let value: UInt64 = buffer.readInteger() else { return nil }
                attributes.size = value
            }
            if flags & flagUIDGID != 0 {
                guard let uid: UInt32 = buffer.readInteger(), let gid: UInt32 = buffer.readInteger() else { return nil }
                attributes.uid = uid
                attributes.gid = gid
            }
            if flags & flagPermissions != 0 {
                guard let value: UInt32 = buffer.readInteger() else { return nil }
                attributes.permissions = value
            }
            if flags & flagTimes != 0 {
                guard let atime: UInt32 = buffer.readInteger(), let mtime: UInt32 = buffer.readInteger() else { return nil }
                attributes.accessed = Date(timeIntervalSince1970: TimeInterval(atime))
                attributes.modified = Date(timeIntervalSince1970: TimeInterval(mtime))
            }
            if flags & flagExtended != 0 {
                // Extended pairs are skipped rather than rejected: a server is entitled to
                // send them, and nothing here needs one.
                guard let count: UInt32 = buffer.readInteger() else { return nil }
                for _ in 0 ..< count {
                    guard readString(from: &buffer) != nil, readString(from: &buffer) != nil else { return nil }
                }
            }
            return attributes
        }
    }

    /// One entry from a directory listing.
    public struct Name: Sendable, Equatable {
        public var filename: String
        /// The `ls -l` style line version 3 sends alongside. Kept because it is the only
        /// place some servers put the symlink target and the owner's name.
        public var longname: String
        public var attributes: Attributes
    }

    // MARK: - Strings

    /// SFTP strings are a length and then bytes, and the bytes are *not* required to be
    /// valid UTF-8 — a filename on a Linux server is a byte string. Decoding leniently
    /// keeps such a file visible rather than hiding it from the person who owns it.
    public static func writeString(_ value: String, into buffer: inout ByteBuffer) {
        let bytes = Array(value.utf8)
        buffer.writeInteger(UInt32(bytes.count))
        buffer.writeBytes(bytes)
    }

    public static func readString(from buffer: inout ByteBuffer) -> String? {
        guard let length: UInt32 = buffer.readInteger(),
              let bytes = buffer.readBytes(length: Int(length))
        else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    public static func readByteString(from buffer: inout ByteBuffer) -> [UInt8]? {
        guard let length: UInt32 = buffer.readInteger() else { return nil }
        return buffer.readBytes(length: Int(length))
    }
}

/// What went wrong, in terms the interface can act on.
public enum SFTPError: Error, Equatable, Sendable {
    case serverRefused(SFTP.Status, String)
    case unsupportedVersion(UInt32)
    case malformed(String)
    case channelClosed
    case cancelled

    public var status: SFTP.Status? {
        if case let .serverRefused(status, _) = self { return status }
        return nil
    }
}
