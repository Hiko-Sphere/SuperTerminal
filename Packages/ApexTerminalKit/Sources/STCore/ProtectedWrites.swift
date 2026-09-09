import Foundation

public extension Data.WritingOptions {
    /// Atomic, and with data protection where the platform actually has it (D-070).
    ///
    /// `completeFileProtection` is an iOS capability. On a Mac — including a Mac Catalyst
    /// build of an iOS app — asking for it makes the write **fail** unless the app carries the
    /// Data Protection capability, which needs a provisioning profile that grants it. That is
    /// not a theory: running this app's own unit tests on Mac Catalyst turned up snippets,
    /// command history, open sessions and known screens all refusing to save, each with the
    /// app's "Changes could not be saved." on it.
    ///
    /// So the flag is asked for where it works. On the Mac the equivalent protection is
    /// FileVault, which is a system-wide setting rather than something a single file requests,
    /// and `docs/HUMAN_ACTIONS.md` records what adding the capability would take.
    static var atomicAndProtected: Data.WritingOptions {
        #if targetEnvironment(macCatalyst)
        [.atomic]
        #else
        [.atomic, .completeFileProtection]
        #endif
    }
}
