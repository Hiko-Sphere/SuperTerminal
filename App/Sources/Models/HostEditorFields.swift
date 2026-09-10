import Foundation

/// What the connection editor can change.
///
/// Separate from ``Host`` so the "apply these edits" step is a function a test can call.
/// The editor does not show everything a connection holds — port-forwarding rules, tags,
/// the detected platform, the environment — and the rule that they survive an edit is
/// worth a test rather than a comment. It did not survive one before: saving an edit
/// erased the connection's port forwards, because a field had been added to the model and
/// not to the editor's constructor call (D-047).
struct HostEditorFields: Equatable {
    var name: String
    var hostname: String
    var port: Int
    var username: String
    var transport: Host.TransportKind
    var credentials: [Host.CredentialReference]
    var folder: String?
    var terminalType: String
    var accessAuthentication: Host.AccessAuthentication?
    var platformOverride: HostPlatform?
    var showsInFiles: Bool
    var jumpHosts: [UUID]
    var forwardsAgent: Bool
    var usesTmux: Bool
    /// Blank means the default session name.
    var tmuxSessionName: String
    /// Which theme this connection opens in, or nil to follow Settings (D-079).
    var themeID: String?
}

extension Host {
    /// The record with the editor's changes applied, and everything else left alone.
    func applying(_ fields: HostEditorFields) -> Host {
        var host = self
        host.name = fields.name
        host.hostname = fields.hostname
        host.port = fields.port
        host.username = fields.username
        host.transport = fields.transport
        host.credentials = fields.credentials
        host.folder = fields.folder
        host.terminalType = fields.terminalType
        host.accessAuthentication = fields.accessAuthentication
        host.platformOverride = fields.platformOverride
        host.showsInFiles = fields.showsInFiles ? true : nil
        // Never left on for a connection that has no key to offer: the toggle is
        // disabled in that state, and a record saved that way would claim a capability
        // the connection cannot deliver.
        host.forwardsAgent = fields.forwardsAgent && fields.credentials.contains(where: {
            if case .privateKey = $0 { return true }
            return false
        }) ? true : nil
        host.jumpHosts = fields.jumpHosts.isEmpty ? nil : fields.jumpHosts
        host.usesTmux = fields.usesTmux ? true : nil
        // A name is only meaningful while tmux is on, and one left behind by a toggle
        // switched off would come back with it and surprise somebody.
        let tmuxName = fields.tmuxSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        host.tmuxSessionName = fields.usesTmux && !tmuxName.isEmpty ? tmuxName : nil
        // An empty string is not a theme; storing one would make "follows Settings" and
        // "asks for the theme called nothing" two different states that look identical.
        let theme = fields.themeID?.trimmingCharacters(in: .whitespacesAndNewlines)
        host.themeID = (theme?.isEmpty ?? true) ? nil : theme
        return host
    }
}
