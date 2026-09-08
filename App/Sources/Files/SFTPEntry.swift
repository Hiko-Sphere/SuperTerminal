import Foundation
import STSFTP

/// One row in the file browser (D-042).
///
/// A view model rather than the protocol's `SFTP.Name`, because what a list needs — a
/// stable identity, a formatted size, a sort key — is not what the wire carries, and
/// putting either into the other makes both harder to change.
struct SFTPEntry: Identifiable, Equatable {
    var name: String
    var attributes: SFTP.Attributes
    /// The absolute path, which is what every operation takes and what makes the row
    /// unique inside one listing.
    var path: String

    var id: String { path }

    var isDirectory: Bool { attributes.isDirectory }
    var isSymbolicLink: Bool { attributes.isSymbolicLink }
    /// A leading dot is how Unix marks a file as hidden; there is no attribute for it.
    var isHidden: Bool { name.hasPrefix(".") }

    var size: UInt64 { attributes.size ?? 0 }
    var modified: Date? { attributes.modified }

    var formattedSize: String? {
        guard !isDirectory, let size = attributes.size else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    /// `rwxr-xr-x`, the way every file manager shows permissions, because the octal is
    /// only readable to people who already know it.
    var formattedPermissions: String? {
        guard let mode = attributes.permissions else { return nil }
        let bits = ["r", "w", "x"]
        var result = isDirectory ? "d" : (isSymbolicLink ? "l" : "-")
        for shift in stride(from: 6, through: 0, by: -3) {
            let group = (mode >> UInt32(shift)) & 0o7
            for (index, letter) in bits.enumerated() {
                result += (group & UInt32(4 >> index)) != 0 ? letter : "-"
            }
        }
        return result
    }

    var symbol: String {
        if isDirectory { return "folder" }
        if isSymbolicLink { return "arrow.turn.up.right" }
        switch (name as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "webp": return "photo"
        case "zip", "gz", "tar", "bz2", "xz", "7z": return "doc.zipper"
        case "sh", "bash", "zsh", "py", "rb", "js", "ts", "swift", "go", "rs", "c", "h", "cpp": return "chevron.left.forwardslash.chevron.right"
        case "json", "yml", "yaml", "toml", "conf", "cfg", "ini": return "gearshape"
        case "md", "txt", "log": return "doc.text"
        default: return "doc"
        }
    }

    /// How a listing is ordered. Directories lead in every mode: a file manager that
    /// scatters them through the list makes navigation a search.
    enum Sort: String, CaseIterable, Identifiable {
        case name, size, modified
        var id: String { rawValue }
    }

    static func sorted(_ entries: [SFTPEntry], by sort: Sort, ascending: Bool) -> [SFTPEntry] {
        entries.sorted { left, right in
            if left.isDirectory != right.isDirectory { return left.isDirectory }
            let result: Bool
            switch sort {
            case .name:
                result = left.name.localizedStandardCompare(right.name) == .orderedAscending
            case .size:
                result = left.size == right.size
                    ? left.name.localizedStandardCompare(right.name) == .orderedAscending
                    : left.size < right.size
            case .modified:
                let a = left.modified ?? .distantPast, b = right.modified ?? .distantPast
                result = a == b
                    ? left.name.localizedStandardCompare(right.name) == .orderedAscending
                    : a < b
            }
            return ascending ? result : !result
        }
    }

    /// Joins a directory and a name without doubling or dropping the separator — the two
    /// ways a path built by hand goes wrong.
    static func join(_ directory: String, _ name: String) -> String {
        if directory == "/" { return "/" + name }
        return directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    /// The parent of an absolute path, or nil at the root.
    static func parent(of path: String) -> String? {
        guard path != "/" else { return nil }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let slash = trimmed.lastIndex(of: "/") else { return nil }
        return slash == trimmed.startIndex ? "/" : String(trimmed[trimmed.startIndex ..< slash])
    }
}
