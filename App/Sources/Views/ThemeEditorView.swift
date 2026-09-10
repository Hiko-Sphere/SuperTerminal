import SwiftUI
import UniformTypeIdentifiers

/// The document `fileExporter` writes when a theme is sent to another terminal.
struct ITermColorsDocument: FileDocument {
    static let readableContentTypes: [UTType] = [ITermColorsFile.contentType, .propertyList]

    let data: Data

    init(theme: TerminalTheme) {
        data = (try? ITermColorsFile.data(for: theme)) ?? Data()
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Editing one palette, with the result on screen the whole time.
///
/// Every change is saved as it is made rather than on a Done button, so the theme the terminal
/// behind this screen is drawing with updates while the colour is being dragged. That is the
/// point of editing a terminal theme: the answer to "is this readable" is not in the swatch.
struct ThemeEditorView: View {
    @Environment(AppContainer.self) private var container
    let themeID: String

    @State private var isExporting = false
    @State private var isConfirmingDeletion = false
    @Environment(\.dismiss) private var dismiss

    private var library: ThemeLibrary {
        ThemeLibrary(settings: container.settings, hosts: container.hostStore)
    }

    private var theme: TerminalTheme? {
        library.custom.first { $0.id == themeID }
    }

    var body: some View {
        Group {
            if let theme {
                editor(theme)
            } else {
                // Reachable: the row can be deleted from another window on iPad while this
                // screen is open.
                ContentUnavailableView(
                    "That theme was deleted",
                    systemImage: "paintpalette",
                    description: Text("It is no longer in your themes.")
                )
            }
        }
        .navigationTitle(theme?.name ?? String(localized: "Theme"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func editor(_ theme: TerminalTheme) -> some View {
        Form {
            Section {
                TerminalThemePreview(
                    theme: theme,
                    fontFamily: container.settings.fontFamily,
                    fontSize: 13
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("theme-preview")
            }

            Section {
                TextField("Name", text: Binding(
                    get: { theme.name },
                    set: { update(theme.with(name: $0)) }
                ))
                .accessibilityIdentifier("theme-name")
            } footer: {
                Text(theme.appearance == .light
                     ? "Offered as a light theme: its background is pale. Which side a theme belongs on is measured from the background rather than taken from its name."
                     : "Offered as a dark theme: its background is dark. Which side a theme belongs on is measured from the background rather than taken from its name.")
            }

            legibility(theme)

            Section {
                colourRow("Background", theme.background) { update(theme.with(background: $0)) }
                colourRow("Text", theme.foreground) { update(theme.with(foreground: $0)) }
                colourRow("Cursor", theme.cursor) { update(theme.with(cursor: $0)) }
                colourRow("Selection", theme.selection) { update(theme.with(selection: $0)) }
            } header: {
                Text("Terminal")
            } footer: {
                Text("The selection colour is drawn behind text, so it needs to differ from the background without hiding what it is highlighting.")
            }

            Section {
                ForEach(0 ..< 8, id: \.self) { index in
                    ansiPair(theme, index: index)
                }
            } header: {
                Text("ANSI colours")
            } footer: {
                Text("Remote programs ask for these by number and expect the classic meanings — colour 1 is the red every diagnostic has ever been printed in. The bright half is what bold text uses.")
            }

            Section {
                Button {
                    isExporting = true
                } label: {
                    Label("Export as .itermcolors…", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("theme-export")
            } footer: {
                Text("Writes the palette in the format terminals on the Mac, Windows and Linux read, so this theme can follow you to the machine you sit at.")
            }

            Section {
                Button(role: .destructive) {
                    isConfirmingDeletion = true
                } label: {
                    Label("Delete Theme", systemImage: "trash")
                }
                .accessibilityIdentifier("theme-delete")
            }
        }
        .confirmationDialog("Delete this theme?", isPresented: $isConfirmingDeletion) {
            Button("Delete", role: .destructive) {
                library.remove(id: theme.id)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            // What it costs, before it is spent: which connections lose their colour.
            Text(library.usage(of: theme.id).consequence
                ?? String(localized: "Nothing is using this theme."))
        }
        .accessibilityIdentifier("theme-editor-form")
        .fileExporter(
            isPresented: $isExporting,
            document: ITermColorsDocument(theme: theme),
            contentType: ITermColorsFile.contentType,
            defaultFilename: theme.name
        ) { _ in }
    }

    // MARK: - Rows

    private func legibility(_ theme: TerminalTheme) -> some View {
        let measure = ThemeLegibility(theme: theme)
        return Section {
            // Combined, so the row is one element that reads "Text on background, 13.3:1"
            // rather than two fragments a screen reader announces separately — and so it has
            // a label at all, which a bare `LabeledContent` container does not.
            LabeledContent("Text on background") {
                Text(measure.ratioText(measure.foregroundRatio))
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("theme-contrast-text")
            LabeledContent("Weakest colour") {
                if let worst = measure.weakest.first {
                    Text("\(measure.ratioText(worst.ratio)) · colour \(worst.index)")
                        .monospacedDigit()
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("theme-contrast-weakest")
            if let caution = measure.caution {
                Label(caution, systemImage: "exclamationmark.triangle")
                    .font(DesignTokens.Typography.callout)
                    .foregroundStyle(DesignTokens.Color.warning)
                    .accessibilityIdentifier("theme-contrast-caution")
            }
        } header: {
            Text("Measured")
        } footer: {
            // Precise about what the number is and is not. A "passes AA" badge on a terminal
            // cell would be a claim the guideline does not actually make.
            Text("Contrast ratios against this theme's own background, from 1:1 to 21:1. A colour under 3:1 is called out because that is the point below which the accessibility guidelines stop treating anything as legible — not because a terminal cell is body text.")
        }
    }

    private func colourRow(
        _ title: LocalizedStringKey,
        _ colour: RGBColor,
        _ change: @escaping (RGBColor) -> Void
    ) -> some View {
        ColorPicker(
            title,
            selection: Binding(
                get: { colour.swiftUIColor },
                set: { change(RGBColor($0)) }
            ),
            supportsOpacity: false
        )
    }

    /// A normal colour and its bright counterpart on one row: they are a pair, and putting
    /// them together is the only way to see that the bright one is actually brighter.
    private func ansiPair(_ theme: TerminalTheme, index: Int) -> some View {
        let name = Self.ansiNames[index]
        return HStack {
            Text(name)
            Spacer(minLength: DesignTokens.Spacing.sm)
            ColorPicker("", selection: Binding(
                get: { theme.ansi[index].swiftUIColor },
                set: { update(theme.with(ansi: replacing(theme.ansi, at: index, with: RGBColor($0)))) }
            ), supportsOpacity: false)
            .labelsHidden()
            .accessibilityLabel(Text(name))
            .accessibilityIdentifier("theme-ansi-\(index)")
            ColorPicker("", selection: Binding(
                get: { theme.ansi[index + 8].swiftUIColor },
                set: { update(theme.with(ansi: replacing(theme.ansi, at: index + 8, with: RGBColor($0)))) }
            ), supportsOpacity: false)
            .labelsHidden()
            .accessibilityLabel(Text(String(localized: "Bright \(name)")))
            .accessibilityIdentifier("theme-ansi-\(index + 8)")
        }
    }

    /// Already localised, because each is also interpolated into "Bright …" for the
    /// bright half's accessibility label.
    private static let ansiNames: [String] = [
        String(localized: "Black"), String(localized: "Red"), String(localized: "Green"),
        String(localized: "Yellow"), String(localized: "Blue"), String(localized: "Magenta"),
        String(localized: "Cyan"), String(localized: "White"),
    ]

    private func replacing(_ colours: [RGBColor], at index: Int, with colour: RGBColor) -> [RGBColor] {
        var updated = colours
        updated[index] = colour
        return updated
    }

    private func update(_ theme: TerminalTheme) {
        library.save(theme)
    }
}
