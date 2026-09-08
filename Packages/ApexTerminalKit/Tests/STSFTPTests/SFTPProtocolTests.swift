import Foundation
import NIOCore
import Testing
@testable import STSFTP

/// The SFTP wire format on its own (D-041). Parsing is where a file client corrupts data
/// silently, so it is pinned here before anything touches a real server.
@Suite("SFTP wire format")
struct SFTPProtocolTests {
    @Test("Attributes round-trip, and absent fields stay absent")
    func attributesRoundTrip() {
        var buffer = ByteBuffer()
        let original = SFTP.Attributes(
            size: 1234, uid: 501, gid: 20, permissions: 0o100_644,
            accessed: Date(timeIntervalSince1970: 1_600_000_000),
            modified: Date(timeIntervalSince1970: 1_600_000_100)
        )
        original.write(into: &buffer)
        let read = SFTP.Attributes.read(from: &buffer)
        #expect(read == original)
        #expect(buffer.readableBytes == 0, "nothing left over")

        // A server that knows only the size sends only the size, and the rest must come
        // back nil rather than as zero — zero is a real uid.
        var sparse = ByteBuffer()
        SFTP.Attributes(size: 7).write(into: &sparse)
        let back = SFTP.Attributes.read(from: &sparse)
        #expect(back?.size == 7)
        #expect(back?.uid == nil && back?.permissions == nil)
    }

    @Test("The POSIX type bits say what a listing entry is")
    func fileTypes() {
        #expect(SFTP.Attributes(permissions: 0o040_755).isDirectory)
        #expect(!SFTP.Attributes(permissions: 0o040_755).isRegularFile)
        #expect(SFTP.Attributes(permissions: 0o100_644).isRegularFile)
        #expect(SFTP.Attributes(permissions: 0o120_777).isSymbolicLink)
        // No permissions at all is not a directory, which is what a wrong guess here
        // would make every unknown entry look like.
        #expect(!SFTP.Attributes().isDirectory)
    }

    @Test("Extended attribute pairs are skipped, not treated as corruption")
    func extendedPairsAreSkipped() {
        var buffer = ByteBuffer()
        buffer.writeInteger(SFTP.Attributes.flagSize | SFTP.Attributes.flagExtended)
        buffer.writeInteger(UInt64(42))
        buffer.writeInteger(UInt32(1))
        SFTP.writeString("acl", into: &buffer)
        SFTP.writeString("something", into: &buffer)
        let attributes = SFTP.Attributes.read(from: &buffer)
        #expect(attributes?.size == 42)
        #expect(buffer.readableBytes == 0, "the pair was consumed")
    }

    @Test("A filename that is not valid UTF-8 still comes back, rather than hiding the file")
    func lenientFilenames() {
        var buffer = ByteBuffer()
        // A lone 0xFF is not valid UTF-8, and is a perfectly legal byte in a Linux name.
        buffer.writeInteger(UInt32(4))
        buffer.writeBytes([0x61, 0xFF, 0x62, 0x63])
        let name = SFTP.readString(from: &buffer)
        #expect(name != nil, "the entry is still listed")
        #expect(name?.hasPrefix("a") == true)
    }

    @Test("A truncated string is nil rather than a partial read")
    func truncatedString() {
        var buffer = ByteBuffer()
        buffer.writeInteger(UInt32(10))
        buffer.writeBytes([1, 2, 3])
        #expect(SFTP.readString(from: &buffer) == nil)
    }
}
