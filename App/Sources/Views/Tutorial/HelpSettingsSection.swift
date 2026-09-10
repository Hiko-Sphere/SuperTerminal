import SwiftUI

/// Everything a person who is stuck would look under "Help": the tour and the guide.
///
/// They were two sections, one directly above the other, **both headed "Help"** — the tour's
/// (D-033) and the guide's (D-056), each added at a different time and each right on its own.
/// Together they read as a rendering fault: the same heading twice, and no way to tell from the
/// headings which half held what you were after. One section, two rows, in the order somebody
/// actually needs them — the tour first, because the person who wants it is newer.
struct HelpSettingsSection: View {
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

            NavigationLink {
                HelpTopicsView()
            } label: {
                Label("User Guide", systemImage: "book")
            }
            .accessibilityIdentifier("settings-guide")
        } header: {
            Text("Help")
        } footer: {
            Text("The tour is six things worth knowing: pasting an address, the first fingerprint, the key row, snippets and the palette, remote screens, and where your keys live. The guide is the whole of it, searchable, with a picture on the topics that are easier shown than described.")
        }
    }
}
