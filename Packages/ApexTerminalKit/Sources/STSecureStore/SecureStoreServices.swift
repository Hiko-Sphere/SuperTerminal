/// The Keychain service names every secret is filed under.
///
/// They live here rather than in the app because the File Provider extension reads the
/// same items from the same shared access group (D-044). Two copies of these strings
/// would be two chances for one of them to drift, and the symptom of a drift is a
/// credential that silently cannot be found.
///
/// Separate services rather than one, so "forget all Cloudflare sessions" and "delete all
/// keys" are each a single scoped delete.
public enum SecureStoreServices {
    public static let privateKeys = "dev.apexterminal.keys"
    /// The Secure Enclave's wrapped references to keys it holds (D-049). A separate
    /// service from `privateKeys` because these are not key material and cannot be
    /// treated like it: they never sync, never export, and mean nothing on another
    /// device. Keeping them apart makes "which of my keys can leave this phone?" a
    /// question the storage layout answers by itself.
    public static let secureEnclaveKeys = "dev.apexterminal.keys.secureenclave"
    public static let passwords = "dev.apexterminal.passwords"
    public static let accessTokens = "dev.apexterminal.cloudflare.tokens"
    public static let serviceTokens = "dev.apexterminal.cloudflare.servicetokens"
    public static let assistant = "dev.apexterminal.assistant"
    public static let vncPasswords = "dev.apexterminal.vnc"
    public static let appLock = "dev.apexterminal.applock"

    /// The access group the app and its extensions share.
    ///
    /// `$(AppIdentifierPrefix)` is not available at runtime, and the prefix is the team
    /// identifier, so callers pass their own bundle's `AppIdentifierPrefix` — read from
    /// the built entitlements — rather than hard-coding a team.
    public static func sharedAccessGroup(teamPrefix: String) -> String {
        "\(teamPrefix)dev.apexterminal.app"
    }
}
