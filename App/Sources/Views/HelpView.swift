import SwiftUI

/// The user guide, in the app.
///
/// A guide nobody opens is a guide nobody wrote, so this is not a wall of text: it is a
/// searchable list of topics, each one short enough to read while the thing it describes
/// is still on screen behind the sheet. Search runs over the whole body, not just the
/// titles — people search for the word in the error message, not for the name of the
/// chapter it is documented under.
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            HelpTopicsView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("help-done")
                    }
                }
        }
    }
}

/// The searchable topic list. Separate from ``HelpView`` because it is shown two ways:
/// as a sheet over the terminal, and pushed onto the Settings stack — and a
/// `NavigationStack` inside another one loses the back button.
struct HelpTopicsView: View {
    @State private var guide: UserGuide?
    @State private var loadError: String?
    @State private var query = ""

    var body: some View {
        content
            .navigationTitle("User Guide")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                guard guide == nil else { return }
                do {
                    guide = try UserGuide.bundled()
                } catch {
                    loadError = error.localizedDescription
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let guide {
            let matches = guide.topics(matching: query)
            List {
                ForEach(matches) { topic in
                    // The destination in place rather than a value and a
                    // `navigationDestination`: this list is pushed onto the Settings stack
                    // as well as shown in its own, and a value-based link resolved against
                    // the wrong stack was measured to dismiss the Settings sheet instead of
                    // pushing the topic.
                    NavigationLink {
                        HelpTopicView(topic: topic)
                    } label: {
                        row(topic)
                    }
                    .accessibilityIdentifier("help-topic-\(topic.slug)")
                }
            }
            .listStyle(.insetGrouped)
            // Placement stated rather than left to SwiftUI: pushed onto the Settings
            // form sheet on iPad, an unplaced `.searchable` rendered no search field at
            // all — measured, the accessibility tree held the topic list, the navigation
            // bar and nothing to type into. The drawer is always shown, so the field is
            // where it is on the phone and does not have to be scrolled up to.
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text("Search the guide")
            )
            .overlay {
                if matches.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .accessibilityIdentifier("help-topics")
        } else if let loadError {
            ContentUnavailableView(loadError, systemImage: "book.closed")
        } else {
            ProgressView()
        }
    }

    private func row(_ topic: UserGuide.Topic) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            Image(systemName: topic.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DesignTokens.Color.accent)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                        .fill(DesignTokens.Color.accent.opacity(0.12))
                )
                // Decorative: the title next to it already says what this is, and a
                // VoiceOver user does not need "cloud, Cloudflare Access and Tunnel".
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(topic.title)
                    .font(DesignTokens.Typography.body.weight(.medium))
                    .foregroundStyle(DesignTokens.Color.label)
                if !topic.summary.isEmpty {
                    Text(topic.summary)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Color.labelSecondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, DesignTokens.Spacing.xxs)
    }
}

/// One topic, rendered with the same Markdown view as the legal texts — the guide and the
/// terms are the same kind of document, and two renderers would drift apart.
struct HelpTopicView: View {
    let topic: UserGuide.Topic

    var body: some View {
        ScrollView {
            MarkdownDocumentView(document: topic.document)
                .padding(.horizontal, DesignTokens.Spacing.lg)
                .padding(.bottom, DesignTokens.Spacing.xl)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
        .navigationTitle(topic.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("help-topic-body")
    }
}
