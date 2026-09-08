import Foundation
import NIOCore
import STCore

/// An SFTP client over one SSH channel (D-041).
///
/// SFTP multiplexes on a single channel by request id: every request carries one, and the
/// reply carries it back. Requests may therefore be in flight together, which is what
/// makes a directory listing and a download able to share a connection — and what makes
/// correlation, not ordering, the thing that has to be right.
///
/// An actor because the id counter, the outstanding table and the read buffer are all
/// mutable state touched from the channel's thread and from callers.
public actor SFTPClient {
    /// Version 3 is what OpenSSH serves. A server offering less is refused rather than
    /// guessed at; a server offering more is used at 3, which the draft allows.
    public static let clientVersion: UInt32 = 3

    /// The largest payload to ask for in one READ. 32 KiB is the value OpenSSH's own
    /// client uses and every server is known to accept; asking for more risks a server
    /// that silently truncates.
    public static let readChunk = 32 * 1024

    private let channel: any SFTPTransport
    private let log: STLogger
    private var nextRequestID: UInt32 = 0
    private var pending: [UInt32: CheckedContinuation<Response, Error>] = [:]
    private var incoming = ByteBuffer()
    private var negotiatedVersion: UInt32?
    private var isClosed = false

    /// A reply, already separated into the shapes a caller can use.
    enum Response {
        case status(SFTP.Status, String)
        case handle([UInt8])
        case data([UInt8])
        case names([SFTP.Name])
        case attributes(SFTP.Attributes)
    }

    public init(transport: any SFTPTransport, log: STLogger) {
        channel = transport
        self.log = log.child(subsystem: "sftp")
    }

    // MARK: - Lifecycle

    /// Sends INIT and waits for VERSION. Nothing else may be sent first.
    public func start() async throws {
        var packet = ByteBuffer()
        packet.writeInteger(Self.clientVersion)
        try await send(.initialise, body: packet, expectsReply: false)

        // VERSION is the one reply that carries no request id, so it is waited for here
        // rather than through the correlation table.
        let deadline = Date().addingTimeInterval(30)
        while negotiatedVersion == nil {
            guard !isClosed else { throw SFTPError.channelClosed }
            guard Date() < deadline else { throw SFTPError.malformed("the server never sent its version") }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let version = negotiatedVersion, version >= 3 else {
            throw SFTPError.unsupportedVersion(negotiatedVersion ?? 0)
        }
        log.info("sftp ready", ["version": "\(version)"])
    }

    public func close() async {
        isClosed = true
        for (_, continuation) in pending { continuation.resume(throwing: SFTPError.channelClosed) }
        pending.removeAll()
        await channel.close()
    }

    /// Called by the transport for every chunk that arrives.
    public func receive(_ data: Data) {
        incoming.writeBytes(data)
        while let packet = takePacket() {
            handle(packet)
        }
    }

    public func transportClosed() {
        isClosed = true
        for (_, continuation) in pending { continuation.resume(throwing: SFTPError.channelClosed) }
        pending.removeAll()
    }

    // MARK: - Operations

    /// Turns a path the user typed into the absolute one the server uses. Also the way to
    /// learn the home directory: version 3 has no other call for it, and `realpath(".")`
    /// is what every client does.
    public func realpath(_ path: String) async throws -> String {
        guard case let .names(names) = try await request(.realpath, string: path), let first = names.first else {
            throw SFTPError.malformed("realpath returned no name")
        }
        return first.filename
    }

    public func listDirectory(_ path: String) async throws -> [SFTP.Name] {
        guard case let .handle(handle) = try await request(.opendir, string: path) else {
            throw SFTPError.malformed("opendir returned no handle")
        }
        defer { Task { try? await self.closeHandle(handle) } }

        var entries: [SFTP.Name] = []
        // READDIR returns a page at a time and signals the end with EOF, not with an
        // empty page, so the loop ends on the status rather than on a count.
        while true {
            var body = ByteBuffer()
            body.writeInteger(UInt32(handle.count))
            body.writeBytes(handle)
            let response = try await request(.readdir, body: body, tolerating: [.eof])
            switch response {
            case let .names(page):
                entries.append(contentsOf: page)
            case let .status(status, _) where status == .eof:
                return entries.filter { $0.filename != "." && $0.filename != ".." }
            case let .status(status, message):
                throw SFTPError.serverRefused(status, message)
            default:
                throw SFTPError.malformed("readdir returned something that is not a listing")
            }
        }
    }

    public func attributes(of path: String, followingLinks: Bool = true) async throws -> SFTP.Attributes {
        let response = try await request(followingLinks ? .stat : .lstat, string: path)
        guard case let .attributes(attributes) = response else {
            throw SFTPError.malformed("stat returned no attributes")
        }
        return attributes
    }

    public func readLink(_ path: String) async throws -> String {
        guard case let .names(names) = try await request(.readlink, string: path), let first = names.first else {
            throw SFTPError.malformed("readlink returned no target")
        }
        return first.filename
    }

    public func makeDirectory(_ path: String, permissions: UInt32? = nil) async throws {
        var body = ByteBuffer()
        SFTP.writeString(path, into: &body)
        SFTP.Attributes(permissions: permissions).write(into: &body)
        try await expectOK(.mkdir, body: body)
    }

    public func removeDirectory(_ path: String) async throws {
        try await expectOK(.rmdir, string: path)
    }

    public func remove(_ path: String) async throws {
        try await expectOK(.remove, string: path)
    }

    /// Version 3's RENAME fails if the destination exists, which is what makes it usable
    /// as the commit step of an atomic write.
    public func rename(from: String, to: String) async throws {
        var body = ByteBuffer()
        SFTP.writeString(from, into: &body)
        SFTP.writeString(to, into: &body)
        try await expectOK(.rename, body: body)
    }

    public func setAttributes(_ attributes: SFTP.Attributes, of path: String) async throws {
        var body = ByteBuffer()
        SFTP.writeString(path, into: &body)
        attributes.write(into: &body)
        try await expectOK(.setstat, body: body)
    }

    // MARK: - Files

    public func open(_ path: String, flags: SFTP.OpenFlags, permissions: UInt32? = nil) async throws -> [UInt8] {
        var body = ByteBuffer()
        SFTP.writeString(path, into: &body)
        body.writeInteger(flags.rawValue)
        SFTP.Attributes(permissions: permissions).write(into: &body)
        guard case let .handle(handle) = try await request(.open, body: body) else {
            throw SFTPError.malformed("open returned no handle")
        }
        return handle
    }

    public func closeHandle(_ handle: [UInt8]) async throws {
        var body = ByteBuffer()
        body.writeInteger(UInt32(handle.count))
        body.writeBytes(handle)
        try await expectOK(.close, body: body)
    }

    /// Reads one chunk. Returns nil at end of file, which SFTP reports as a status rather
    /// than as a short read — a short read is legal and does not mean the end.
    public func read(handle: [UInt8], offset: UInt64, length: Int) async throws -> [UInt8]? {
        var body = ByteBuffer()
        body.writeInteger(UInt32(handle.count))
        body.writeBytes(handle)
        body.writeInteger(offset)
        body.writeInteger(UInt32(length))
        let response = try await request(.read, body: body, tolerating: [.eof])
        switch response {
        case let .data(bytes): return bytes
        case let .status(status, _) where status == .eof: return nil
        case let .status(status, message): throw SFTPError.serverRefused(status, message)
        default: throw SFTPError.malformed("read returned something that is not data")
        }
    }

    public func write(handle: [UInt8], offset: UInt64, bytes: [UInt8]) async throws {
        var body = ByteBuffer()
        body.writeInteger(UInt32(handle.count))
        body.writeBytes(handle)
        body.writeInteger(offset)
        body.writeInteger(UInt32(bytes.count))
        body.writeBytes(bytes)
        try await expectOK(.write, body: body)
    }

    // MARK: - Request plumbing

    private func expectOK(_ type: SFTP.PacketType, string: String) async throws {
        var body = ByteBuffer()
        SFTP.writeString(string, into: &body)
        try await expectOK(type, body: body)
    }

    private func expectOK(_ type: SFTP.PacketType, body: ByteBuffer) async throws {
        let response = try await request(type, body: body, tolerating: [.ok])
        guard case let .status(status, message) = response else {
            throw SFTPError.malformed("\(type) returned something that is not a status")
        }
        guard status == .ok else { throw SFTPError.serverRefused(status, message) }
    }

    private func request(_ type: SFTP.PacketType, string: String) async throws -> Response {
        var body = ByteBuffer()
        SFTP.writeString(string, into: &body)
        return try await request(type, body: body)
    }

    /// Sends a request and waits for the reply with the same id. `tolerating` names the
    /// statuses the caller wants to see rather than have thrown, so end-of-file and
    /// success can be handled as values.
    private func request(
        _ type: SFTP.PacketType,
        body: ByteBuffer,
        tolerating tolerated: Set<SFTP.Status> = []
    ) async throws -> Response {
        guard !isClosed else { throw SFTPError.channelClosed }
        let id = nextID()
        var packet = ByteBuffer()
        packet.writeInteger(id)
        var body = body
        packet.writeBuffer(&body)

        let response: Response = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task {
                do {
                    try await self.send(type, body: packet, expectsReply: true)
                } catch {
                    self.failPending(id, with: error)
                }
            }
        }
        if case let .status(status, message) = response, status != .ok, !tolerated.contains(status) {
            throw SFTPError.serverRefused(status, message)
        }
        return response
    }

    private func failPending(_ id: UInt32, with error: Error) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: error)
    }

    private func nextID() -> UInt32 {
        nextRequestID &+= 1
        // Zero is avoided so a reply carrying a default-initialised id cannot look like a
        // legitimate one.
        if nextRequestID == 0 { nextRequestID = 1 }
        return nextRequestID
    }

    private func send(_ type: SFTP.PacketType, body: ByteBuffer, expectsReply: Bool) async throws {
        var packet = ByteBuffer()
        packet.writeInteger(UInt32(body.readableBytes + 1))
        packet.writeInteger(type.rawValue)
        var body = body
        packet.writeBuffer(&body)
        try await channel.send(Data(packet.readableBytesView))
    }

    // MARK: - Framing

    /// One complete packet, or nil while the rest of it is still arriving.
    private func takePacket() -> ByteBuffer? {
        guard let length: UInt32 = incoming.getInteger(at: incoming.readerIndex) else { return nil }
        // A length a server could never legitimately send is a framing error, not an
        // allocation to attempt.
        guard length > 0, length <= 1_048_576 else {
            log.error("sftp framing", ["length": "\(length)"])
            isClosed = true
            return nil
        }
        guard incoming.readableBytes >= 4 + Int(length) else { return nil }
        incoming.moveReaderIndex(forwardBy: 4)
        let packet = incoming.readSlice(length: Int(length))
        incoming.discardReadBytes()
        return packet
    }

    private func handle(_ packet: ByteBuffer) {
        var packet = packet
        guard let raw: UInt8 = packet.readInteger(), let type = SFTP.PacketType(rawValue: raw) else { return }

        if type == .version {
            negotiatedVersion = packet.readInteger() ?? 0
            return
        }
        guard let id: UInt32 = packet.readInteger() else { return }
        guard let continuation = pending.removeValue(forKey: id) else {
            // A reply to a request nobody is waiting for — a cancelled read, most likely.
            // Dropping it is correct; the alternative is holding it forever.
            return
        }

        switch type {
        case .status:
            let code = packet.readInteger(as: UInt32.self) ?? SFTP.Status.failure.rawValue
            let message = SFTP.readString(from: &packet) ?? ""
            continuation.resume(returning: .status(SFTP.Status(rawValue: code) ?? .failure, message))
        case .handle:
            guard let handle = SFTP.readByteString(from: &packet) else {
                continuation.resume(throwing: SFTPError.malformed("a handle without bytes"))
                return
            }
            continuation.resume(returning: .handle(handle))
        case .data:
            guard let bytes = SFTP.readByteString(from: &packet) else {
                continuation.resume(throwing: SFTPError.malformed("a data packet without bytes"))
                return
            }
            continuation.resume(returning: .data(bytes))
        case .attrs:
            guard let attributes = SFTP.Attributes.read(from: &packet) else {
                continuation.resume(throwing: SFTPError.malformed("attributes that do not parse"))
                return
            }
            continuation.resume(returning: .attributes(attributes))
        case .name:
            guard let count: UInt32 = packet.readInteger() else {
                continuation.resume(throwing: SFTPError.malformed("a name packet without a count"))
                return
            }
            var names: [SFTP.Name] = []
            for _ in 0 ..< count {
                guard let filename = SFTP.readString(from: &packet),
                      let longname = SFTP.readString(from: &packet),
                      let attributes = SFTP.Attributes.read(from: &packet)
                else {
                    continuation.resume(throwing: SFTPError.malformed("a truncated name list"))
                    return
                }
                names.append(SFTP.Name(filename: filename, longname: longname, attributes: attributes))
            }
            continuation.resume(returning: .names(names))
        default:
            continuation.resume(throwing: SFTPError.malformed("unexpected packet \(type)"))
        }
    }
}

/// What an `SFTPClient` needs from the channel underneath it. A protocol so the framing
/// and correlation can be tested without a network, and so the same client works over an
/// SSH channel or anything else that carries bytes in order.
public protocol SFTPTransport: Sendable {
    func send(_ data: Data) async throws
    func close() async
}
