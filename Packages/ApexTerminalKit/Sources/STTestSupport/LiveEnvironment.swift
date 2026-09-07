import Foundation

/// Configuration for the live Cloudflare end-to-end run, read from the process
/// environment.
///
/// Nothing here is ever committed. The values name a real Access application and a real
/// SSH account, so they are supplied at run time and the repository holds only this
/// description of their shape. `scripts/live-e2e.sh` documents how to set them.
public struct LiveEnvironment: Sendable {
    /// The Access-protected hostname, e.g. `ssh.example.com`.
    public let hostname: String
    /// SSH username on the origin host.
    public let username: String
    /// Optional destination when the tunnel runs in bastion mode.
    public let jumpDestination: String?

    /// Non-interactive Access credential. Present for automated runs; absent when the
    /// run is testing the interactive browser login instead.
    public let serviceTokenID: String?
    public let serviceTokenSecret: String?

    /// SSH credential for the origin. Exactly one of these is required.
    public let privateKeyPEM: String?
    public let privateKeyPassphrase: String?
    public let password: String?

    /// Expected SHA-256 host key fingerprint (`SHA256:…`), so the live run pins rather
    /// than trusting on first use.
    public let expectedHostKeyFingerprint: String?

    public enum Key: String, CaseIterable, Sendable {
        case hostname = "ST_LIVE_CF_HOSTNAME"
        case username = "ST_LIVE_SSH_USER"
        case jumpDestination = "ST_LIVE_CF_JUMP_DESTINATION"
        case serviceTokenID = "ST_LIVE_CF_SERVICE_TOKEN_ID"
        case serviceTokenSecret = "ST_LIVE_CF_SERVICE_TOKEN_SECRET"
        case privateKeyPath = "ST_LIVE_SSH_KEY_PATH"
        case privateKeyPassphrase = "ST_LIVE_SSH_KEY_PASSPHRASE"
        case password = "ST_LIVE_SSH_PASSWORD"
        case expectedHostKeyFingerprint = "ST_LIVE_SSH_HOST_FINGERPRINT"
    }

    /// Reads the environment, returning `nil` when the live run is not configured.
    ///
    /// Returning `nil` rather than throwing is deliberate: a developer without a
    /// Cloudflare account should get a clean skip, not a failure they cannot act on. The
    /// run that *does* have credentials fails loudly on any problem.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> LiveEnvironment? {
        func value(_ key: Key) -> String? {
            guard let raw = environment[key.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty
            else { return nil }
            return raw
        }

        guard let hostname = value(.hostname), let username = value(.username) else { return nil }

        var privateKeyPEM: String?
        if let path = value(.privateKeyPath) {
            privateKeyPEM = try? String(contentsOfFile: path, encoding: .utf8)
        }

        return LiveEnvironment(
            hostname: hostname,
            username: username,
            jumpDestination: value(.jumpDestination),
            serviceTokenID: value(.serviceTokenID),
            serviceTokenSecret: value(.serviceTokenSecret),
            privateKeyPEM: privateKeyPEM,
            privateKeyPassphrase: value(.privateKeyPassphrase),
            password: value(.password),
            expectedHostKeyFingerprint: value(.expectedHostKeyFingerprint)
        )
    }

    /// Whether a non-interactive Access credential is available.
    public var hasServiceToken: Bool { serviceTokenID != nil && serviceTokenSecret != nil }

    /// Human-readable summary for the test log. Contains no secrets.
    public var summary: String {
        var parts = ["host=\(hostname)", "user=\(username)"]
        parts.append(hasServiceToken ? "access=service-token" : "access=none-or-interactive")
        parts.append(privateKeyPEM != nil ? "ssh=key" : (password != nil ? "ssh=password" : "ssh=missing"))
        if jumpDestination != nil { parts.append("bastion=yes") }
        if expectedHostKeyFingerprint != nil { parts.append("hostkey=pinned") }
        return parts.joined(separator: " ")
    }
}
