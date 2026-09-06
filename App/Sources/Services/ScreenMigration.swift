import Foundation
import STCore

/// Moves screens configured inside an SSH connection out into their own records (D-027).
///
/// Before, a screen was a section in the SSH connection's editor and lived in that
/// connection's record. It is now a connection of its own. Everything already set up must
/// come across without the user doing anything, on every device, without the same screen
/// appearing twice when two devices migrate independently.
enum ScreenMigration {
    /// What an old `vnc` block becomes. Pure, so the mapping is testable on its own.
    ///
    /// The address is the one the old code actually dialled: through SSH, the target as
    /// the server sees it (the server's own desktop when unset); direct, the SSH host's
    /// own hostname, which is what the direct path used.
    static func screen(fromLegacy host: Host) -> ScreenConnection? {
        guard let vnc = host.vnc else { return nil }
        return ScreenConnection(
            id: ScreenConnection.migratedID(fromHostID: host.id),
            name: String(localized: "\(host.name) Screen"),
            address: vnc.viaSSH ? (vnc.targetHost ?? "127.0.0.1") : host.hostname,
            port: vnc.port,
            route: vnc.viaSSH ? .throughSSH(hostID: host.id) : .direct,
            hasPassword: vnc.hasPassword,
            folder: host.folder,
            tags: host.tags
        )
    }

    /// Runs once per launch, before anything can sync. Safe to run again: each step checks
    /// its own precondition, so a run interrupted half way finishes on the next launch.
    @MainActor
    static func runAtLaunch(hosts: HostStore, screens: ScreenStore, vault: CredentialVault, log: STLogger) {
        var migrated = 0
        var passwordsMoved = 0
        for host in hosts.hosts where host.vnc != nil {
            guard var screen = screen(fromLegacy: host) else { continue }

            // The password moves before the record is stripped, and is stored before it is
            // deleted: an interruption can leave it in both places, never in neither.
            if vault.hasVNCPassword(hostID: host.id) {
                do {
                    if let password = try vault.loadVNCPassword(hostID: host.id) {
                        try vault.storeVNCPassword(password, screenID: screen.id)
                        try vault.deleteVNCPassword(hostID: host.id)
                        passwordsMoved += 1
                        screen.hasPassword = true
                    }
                } catch {
                    // The device may be locked — a Siri intent can launch the app before
                    // first unlock, and these items are `whenUnlockedThisDeviceOnly`. That
                    // is "try again next launch", never "there is no password".
                    log.info("screen password could not be moved yet; leaving the connection as it is")
                    continue
                }
            }

            if screens.insertIfAbsent(screen) { migrated += 1 }

            var stripped = host
            stripped.vnc = nil
            // Not stamped: the stripped connection is not pushed until the user edits it,
            // so a device still on the old version keeps its own working screen until it
            // upgrades and migrates its own copy — to the same id, which then merges.
            hosts.update(stripped, stamping: false)
        }
        if migrated > 0 || passwordsMoved > 0 {
            log.info("screens migrated", ["screens": "\(migrated)", "passwords": "\(passwordsMoved)"])
        }
    }
}
