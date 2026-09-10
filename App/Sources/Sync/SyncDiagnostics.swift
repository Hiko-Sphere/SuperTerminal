#if DEBUG
import CloudKit
import Foundation

/// Writes the whole of a sync failure to a file, for a developer to read off the device.
///
/// Debug only, deliberately. The shipped "Export diagnostics" contains no hostnames,
/// commands or credentials, and a CloudKit error can carry record names — which for a
/// known host embed the hostname. This exists so a failure that says only "the server
/// refused" can be read in full during development, and it is compiled out of anything
/// that could reach a user.
enum SyncDiagnostics {
    /// What was being attempted. Without it the log is one unlabelled error and a fetch
    /// failure cannot be told from a send failure — which is how the one dump this project
    /// ever took came to be read as proof about pushes when nothing in it said so.
    enum Operation: String {
        case fetch
        case send
        case purge
        case accountStatus
        case zoneSave
        case recordSave
    }

    static func record(_ error: Error, doing operation: Operation, in directory: URL) {
        let text = describe(error, depth: 0)
        let url = directory.appendingPathComponent("sync-failure.log")
        let stamped = "\(Date().formatted(.iso8601)) operation=\(operation.rawValue)\n\(text)\n\n"
        // Appended, not overwritten. A run produces a fetch, a zone save and a series of
        // record saves; keeping only the last of them throws away the sequence, which is the
        // part that says which one failed first.
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(stamped.utf8))
        } else {
            try? stamped.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func describe(_ error: Error, depth: Int) -> String {
        guard depth < 4 else { return "…" }
        let ns = error as NSError
        var lines = ["domain=\(ns.domain) code=\(ns.code)", "description=\(ns.localizedDescription)"]
        for (key, value) in ns.userInfo.sorted(by: { $0.key < $1.key }) {
            if let underlying = value as? NSError {
                lines.append("\(key):\n" + indent(describe(underlying, depth: depth + 1)))
            } else if let partial = value as? [AnyHashable: Any] {
                // A partial failure keeps the reason per item, which is where CloudKit
                // actually says what it did not like.
                for (item, itemError) in partial {
                    let inner = (itemError as? Error).map { describe($0, depth: depth + 1) } ?? "\(itemError)"
                    lines.append("\(key)[\(item)]:\n" + indent(inner))
                }
            } else {
                lines.append("\(key)=\(value)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func indent(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n")
    }
}
#endif
