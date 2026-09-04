import Foundation

/// Reader for the SSH binary encoding (RFC 4251 §5) used by OpenSSH key files.
///
/// Every read is bounds-checked and returns `nil` rather than trapping, because this
/// parser runs on files the user imported from elsewhere: a malformed or hostile key
/// file must produce an error message, never a crash.
struct SSHWireReader {
    private let bytes: [UInt8]
    private var offset: Int = 0

    init(_ data: Data) {
        bytes = Array(data)
    }

    var remaining: Int { bytes.count - offset }
    var isAtEnd: Bool { offset >= bytes.count }

    mutating func readUInt32() -> UInt32? {
        guard remaining >= 4 else { return nil }
        defer { offset += 4 }
        return (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    mutating func readBytes(_ count: Int) -> Data? {
        guard count >= 0, remaining >= count else { return nil }
        defer { offset += count }
        return Data(bytes[offset ..< (offset + count)])
    }

    /// Reads a length-prefixed byte string.
    ///
    /// The declared length is never trusted: `readBytes` refuses anything longer than
    /// what is actually present, so a truncated or hostile file yields `nil` rather
    /// than an over-read.
    mutating func readString() -> Data? {
        guard let length = readUInt32() else { return nil }
        return readBytes(Int(length))
    }

    mutating func readStringUTF8() -> String? {
        guard let data = readString() else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Reads an `mpint` and returns it as a fixed-width big-endian magnitude with any
    /// OpenSSH sign-padding byte removed.
    mutating func readMPInt() -> Data? {
        guard var data = readString() else { return nil }
        while data.first == 0x00, data.count > 1 { data = data.dropFirst() }
        return data
    }

    mutating func readAll() -> Data {
        defer { offset = bytes.count }
        return Data(bytes[offset...])
    }
}

/// Writer for the SSH binary encoding.
struct SSHWireWriter {
    private(set) var data = Data()

    mutating func writeUInt32(_ value: UInt32) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    mutating func writeString(_ value: Data) {
        writeUInt32(UInt32(value.count))
        data.append(value)
    }

    mutating func writeString(_ value: String) {
        writeString(Data(value.utf8))
    }

    mutating func writeRaw(_ value: Data) {
        data.append(value)
    }
}
