import STFileProvider
import SwiftUI

/// The switch that puts one server in the Files app (D-044).
///
/// It is in the connection's own editor rather than in Settings because that is where the
/// user already decides what this server is; a separate list of "servers in Files" would
/// be a second place to keep in step.
///
/// The switch explains itself when it cannot be turned on. A disabled control with no
/// reason is a dead end, and every reason here is something the user can fix: give the
/// connection a user name, save a credential the app can use without asking, or connect
/// once so the host key is checked.
struct HostFilesSection: View {
    @Environment(AppContainer.self) private var container
    let host: Host
    @Binding var showsInFiles: Bool

    @State private var verdict: DomainPublishability?

    var body: some View {
        Section {
            Toggle("Show in the Files app", isOn: $showsInFiles)
                .disabled(!isAvailable)
                .accessibilityIdentifier("files-domain-toggle")
        } header: {
            Text("Files")
        } footer: {
            Text(footer)
        }
        .task { verdict = await container.files.publishability(of: host) }
    }

    private var isAvailable: Bool {
        container.files.isAvailable && verdict == .publishable
    }

    private var footer: String {
        if let reason = container.files.unavailableReason { return reason }
        if let explanation = verdict?.explanation { return explanation }
        // What the user is promised, and what they are not. An extension is started by
        // the system when Files needs it and stopped again soon after, so claiming a
        // permanently mounted drive would be a promise iOS does not let anyone keep.
        return String(localized: "This server appears in the Files app, where you can browse it, open files and save them back. Apex Terminal connects when Files asks and disconnects shortly after, so a change made on the server appears when you open or refresh the folder.")
    }
}
