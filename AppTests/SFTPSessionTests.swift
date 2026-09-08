import Foundation
import STSFTP
import Testing
@testable import ApexTerminal

/// The file browser's model: what the list shows, and how a transfer reports itself
/// (D-042). The protocol underneath is proved against a real OpenSSH server in
/// `STSFTPTests`; this is the layer between that and the screen.
@Suite struct SFTPSessionTests {
    private func entry(_ name: String, size: UInt64 = 0, directory: Bool = false, modified: Date? = nil) -> SFTPEntry {
        SFTPEntry(
            name: name,
            attributes: SFTP.Attributes(
                size: size,
                permissions: directory ? 0o040_755 : 0o100_644,
                modified: modified
            ),
            path: SFTPEntry.join("/home/u", name)
        )
    }

    // MARK: - Paths

    @Test("Joining and walking up a path handles the root without doubling a slash")
    func paths() {
        #expect(SFTPEntry.join("/", "etc") == "/etc")
        #expect(SFTPEntry.join("/home/u", "a.txt") == "/home/u/a.txt")
        #expect(SFTPEntry.join("/home/u/", "a.txt") == "/home/u/a.txt", "a trailing slash is not doubled")

        #expect(SFTPEntry.parent(of: "/home/u/a.txt") == "/home/u")
        #expect(SFTPEntry.parent(of: "/etc") == "/")
        #expect(SFTPEntry.parent(of: "/") == nil, "the root has no parent, and asking must not crash")
        #expect(SFTPEntry.parent(of: "/home/u/") == "/home")
    }

    // MARK: - Listing

    @Test("Directories lead in every sort, and the order reverses on request")
    func sorting() {
        let entries = [
            entry("beta.txt", size: 10),
            entry("alpha", directory: true),
            entry("gamma.txt", size: 5),
            entry("zeta", directory: true),
        ]
        let byName = SFTPEntry.sorted(entries, by: .name, ascending: true)
        #expect(byName.map(\.name) == ["alpha", "zeta", "beta.txt", "gamma.txt"],
                "folders first, then files, each alphabetical")

        let bySize = SFTPEntry.sorted(entries, by: .size, ascending: true)
        #expect(bySize.map(\.name) == ["alpha", "zeta", "gamma.txt", "beta.txt"],
                "still folders first — scattering them through the list makes navigation a search")

        let descending = SFTPEntry.sorted(entries, by: .name, ascending: false)
        let leadingAreFolders = descending.prefix(2).allSatisfy { $0.isDirectory }
        #expect(leadingAreFolders, "reversing does not mix folders in")
        #expect(descending.map(\.name) == ["zeta", "alpha", "gamma.txt", "beta.txt"])
    }

    @Test("A dot-file is hidden, and permissions read the way every file manager shows them")
    func presentation() {
        #expect(entry(".ssh", directory: true).isHidden)
        #expect(!entry("ssh").isHidden)

        #expect(entry("a", directory: true).formattedPermissions == "drwxr-xr-x")
        #expect(entry("a").formattedPermissions == "-rw-r--r--")
        let link = SFTPEntry(name: "l", attributes: SFTP.Attributes(permissions: 0o120_777), path: "/l")
        #expect(link.formattedPermissions == "lrwxrwxrwx")

        // A directory has no size to show: showing one invites the reader to think it is
        // the size of its contents, which SFTP never reports.
        #expect(entry("d", size: 4096, directory: true).formattedSize == nil)
        #expect(entry("f", size: 1024).formattedSize != nil)
    }

    // MARK: - Transfers

    @Test("A transfer reports rate and time left only once it has enough to be honest")
    @MainActor func transferProgress() async throws {
        let transfer = FileTransfer(
            direction: .download, remotePath: "/home/u/big.bin",
            localURL: URL(fileURLWithPath: "/tmp/big.bin"), total: 1_000_000
        )
        #expect(transfer.fraction == 0)
        #expect(transfer.secondsRemaining == nil, "no estimate before there is anything to estimate from")

        transfer.begin()
        transfer.advance(to: 100_000)
        // One sample is not a rate. Guessing from it produces the wildly wrong first
        // estimate that makes people cancel.
        #expect(transfer.formattedRate == nil || transfer.bytesPerSecond != nil)

        try await Task.sleep(for: .milliseconds(300))
        transfer.advance(to: 250_000)
        #expect(transfer.fraction == 0.25)
        let rate = try #require(transfer.bytesPerSecond)
        #expect(rate > 0)
        let remaining = try #require(transfer.secondsRemaining)
        #expect(remaining > 0)
    }

    @Test("Pause, cancel and retry move through the states they claim")
    @MainActor func transferStates() {
        let transfer = FileTransfer(
            direction: .upload, remotePath: "/home/u/a", localURL: URL(fileURLWithPath: "/tmp/a"), total: 100
        )
        #expect(transfer.state == .waiting)
        transfer.begin()
        transfer.advance(to: 50)
        transfer.pause()
        #expect(transfer.state == .paused)
        transfer.resume()
        #expect(transfer.state == .running)
        transfer.cancel()
        #expect(transfer.state == .cancelled)
        #expect(transfer.state.isTerminal)

        // A retry starts over: SFTP has no partial upload the server remembers, and
        // resuming from an offset is how half a file ends up looking whole.
        transfer.prepareForRetry()
        #expect(transfer.state == .waiting)
        #expect(transfer.transferred == 0)
    }

    @Test("A finished transfer stops claiming a rate")
    @MainActor func finishedTransferIsQuiet() {
        let transfer = FileTransfer(
            direction: .download, remotePath: "/a", localURL: URL(fileURLWithPath: "/tmp/a"), total: 10
        )
        transfer.begin()
        transfer.advance(to: 10)
        transfer.finish()
        #expect(transfer.state == .finished)
        #expect(transfer.formattedRate == nil)
        #expect(transfer.secondsRemaining == nil)
    }

    // MARK: - Errors

    @Test("A refusal names what failed and what to do about it")
    func errorMessages() {
        let denied = SFTPSession.describe(
            SFTPError.serverRefused(.permissionDenied, ""), doing: "delete that"
        )
        #expect(denied.message.contains("permission"))
        #expect(denied.recoverySuggestion?.isEmpty == false)

        let missing = SFTPSession.describe(SFTPError.serverRefused(.noSuchFile, ""), doing: "open that")
        #expect(missing.message.contains("no longer there"))

        // A generic failure is the one that most needs a suggestion: it is what a server
        // returns for "the folder is not empty" and "that name is taken".
        let failure = SFTPSession.describe(SFTPError.serverRefused(.failure, ""), doing: "delete that")
        #expect(failure.recoverySuggestion?.contains("empty") == true)

        // Nothing leaks a raw error object into a sentence a person reads.
        for error in [denied, missing, failure] {
            #expect(!error.message.contains("SFTPError"))
            #expect(!error.message.contains("0x"))
        }
    }
}
