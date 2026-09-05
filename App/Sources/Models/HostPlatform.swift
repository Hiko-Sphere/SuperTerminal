import Foundation

/// The operating system behind a connection, found by asking the server or set by hand.
///
/// It is not decoration: the assistant is told which platform a command is for, the row
/// shows which kind of machine a saved connection is, and a wrong guess is corrected in
/// the editor rather than argued with. Detection runs on its own channel after the shell
/// is up, so it never delays the prompt and never types into the user's session.
public enum HostPlatform: String, Codable, CaseIterable, Sendable, Hashable {
    case macOS, linux, windows, bsd, other

    /// What the row and the picker show.
    public var title: String {
        switch self {
        case .macOS: String(localized: "macOS")
        case .linux: String(localized: "Linux")
        case .windows: String(localized: "Windows")
        case .bsd: String(localized: "BSD")
        case .other: String(localized: "Other system")
        }
    }

    public var systemImage: String {
        switch self {
        case .macOS: "apple.logo"
        case .linux: "server.rack"
        case .windows: "pc"
        case .bsd: "server.rack"
        case .other: "questionmark.circle"
        }
    }

    /// The commands detection runs, in order. `uname -s` answers on every POSIX system;
    /// Windows OpenSSH has no `uname`, so its shell reports an unknown command and the
    /// second command asks `cmd` for the version string instead.
    public static let unameCommand = "uname -s"
    public static let windowsVersionCommand = "cmd /c ver"

    /// Reads a platform out of what the server printed.
    ///
    /// - Parameters:
    ///   - unameOutput: standard output of `uname -s`, or nil when it could not be run.
    ///   - windowsVersionOutput: standard output of `cmd /c ver`, or nil when it was not
    ///     run or could not be run.
    /// - Returns: nil when neither answer identifies a system, so the caller keeps whatever
    ///   it knew before rather than overwriting it with a guess.
    public static func detect(unameOutput: String?, windowsVersionOutput: String?) -> HostPlatform? {
        if let uname = unameOutput?.trimmingCharacters(in: .whitespacesAndNewlines), !uname.isEmpty {
            let kernel = uname.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)?.lowercased() ?? ""
            switch kernel {
            case "darwin": return .macOS
            case "linux": return .linux
            case "freebsd", "openbsd", "netbsd", "dragonfly": return .bsd
            case "sunos", "aix", "hp-ux", "haiku", "minix": return .other
            case "":
                break
            default:
                // A kernel name that is not one of the above, but is a kernel name (one
                // word, no "not recognized" text): MSYS/Cygwin/WSL-style strings such as
                // `MINGW64_NT-10.0` or `CYGWIN_NT-10.0` are Windows underneath.
                if kernel.hasPrefix("mingw") || kernel.hasPrefix("msys") || kernel.hasPrefix("cygwin") {
                    return .windows
                }
                if !uname.localizedCaseInsensitiveContains("not recognized"),
                   !uname.localizedCaseInsensitiveContains("not found"),
                   !uname.localizedCaseInsensitiveContains("is not") {
                    return .other
                }
            }
        }
        if let version = windowsVersionOutput?.trimmingCharacters(in: .whitespacesAndNewlines),
           version.localizedCaseInsensitiveContains("windows") {
            return .windows
        }
        return nil
    }
}
