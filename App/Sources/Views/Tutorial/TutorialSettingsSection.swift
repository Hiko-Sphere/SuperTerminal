import SwiftUI

/// Where the tour is found again once it has been skipped or finished (D-033).
///
/// Its own section rather than a row tucked into another one: someone looking for it is
/// looking for help, and help that is filed under "Terminal" or "Security" is not found.
struct TutorialSettingsSection: View {
    @Environment(AppContainer.self) private var container
    @State private var isShowingTutorial = false

    var body: some View {
        Section {
            Button {
                isShowingTutorial = true
            } label: {
                Label("Show the tour again", systemImage: "graduationcap")
            }
            .accessibilityIdentifier("settings-tutorial")
            // The cover hangs off the button rather than the Section: a Section is not a
            // view, and a presentation attached to one is silently dropped.
            .fullScreenCover(isPresented: $isShowingTutorial) {
                TutorialView { isShowingTutorial = false }
                    .environment(container)
            }
        } header: {
            Text("Help")
        } footer: {
            Text("Six things worth knowing: pasting an address, the first fingerprint, the key row, snippets and the palette, remote screens, and where your keys live.")
        }
    }
}
