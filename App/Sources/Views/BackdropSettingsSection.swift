import PhotosUI
import STCore
import SwiftUI

/// Choosing a picture to put behind the terminal (D-077).
///
/// The control this deliberately does **not** offer is an opacity slider. That is the shortcut
/// every competing app took and the reason the feature has a bad name: it makes illegibility the
/// user's fault. Here the dimming is *solved* from the picture's own measured extremes and the
/// theme's background, and the person chooses how much contrast they are willing to spend — with
/// each choice stating what it costs, in the only terms that can be proved.
struct BackdropSettingsSection: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    @State private var picked: PhotosPickerItem?
    @State private var problem: String?
    @State private var isWorking = false

    var body: some View {
        @Bindable var settings = container.settings

        Section {
            if let backdrop = settings.backdrop {
                strengthPicker(backdrop)
                softnessSlider(backdrop)
                placementPicker(backdrop)
                measuredNote(backdrop)
                replaceButton
                Button(role: .destructive) {
                    remove(backdrop)
                } label: {
                    Label("Remove Picture", systemImage: "trash")
                }
                .accessibilityIdentifier("backdrop-remove")
            } else {
                // `PhotosPicker` runs out of process, so it needs no photo-library permission and
                // raises no prompt. Adding `NSPhotoLibraryUsageDescription` would turn a
                // permission-free flow into one that asks.
                PhotosPicker(selection: $picked, matching: .images, photoLibrary: .shared()) {
                    Label("Choose a Picture…", systemImage: "photo")
                }
                .accessibilityIdentifier("backdrop-choose")
            }

            if let suppression {
                Label(suppression, systemImage: "eye.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("backdrop-suppressed")
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(DesignTokens.Color.danger)
                    .accessibilityIdentifier("backdrop-problem")
            }
        } header: {
            Text("Backdrop")
        } footer: {
            Text("A picture behind the terminal. How much of it shows is worked out from the picture itself and the theme you are using, so the text keeps the contrast the strength below promises — rather than leaving you to find a readable setting by eye.")
        }
        .accessibilityIdentifier("settings-backdrop")
        .task(id: picked) { await importPicked() }
    }

    // MARK: - Rows

    private func strengthPicker(_ backdrop: Backdrop) -> some View {
        // A menu rather than a segmented control: segmented truncates its labels at accessibility
        // text sizes, and these labels are the whole point.
        Picker(selection: Binding(
            get: { backdrop.strength },
            set: { value in change(backdrop) { $0.strength = value } }
        )) {
            ForEach(Backdrop.Strength.allCases) { strength in
                Text(strength.title).tag(strength)
            }
        } label: {
            Text("Strength")
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("backdrop-strength")
    }

    private func softnessSlider(_ backdrop: Backdrop) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text("Softness")
            Slider(
                value: Binding(
                    get: { backdrop.softness },
                    set: { value in Task { await resoften(backdrop, to: value) } }
                ),
                in: Backdrop.softnessRange
            )
            .accessibilityIdentifier("backdrop-softness")
            Text("Blurring a picture flattens it, which usually lets more of it show.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func placementPicker(_ backdrop: Backdrop) -> some View {
        Picker(selection: Binding(
            get: { backdrop.placement },
            set: { value in change(backdrop) { $0.placement = value } }
        )) {
            ForEach(Backdrop.Placement.allCases) { placement in
                Text(placement.title).tag(placement)
            }
        } label: {
            Text("Placement")
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("backdrop-placement")
    }

    /// What the current choice actually costs, measured against the theme in use.
    private func measuredNote(_ backdrop: Backdrop) -> some View {
        let dimming = BackdropBaker.dimming(for: backdrop, background: currentBackground)
        let shown = Int(((1 - dimming) * 100).rounded())
        return VStack(alignment: .leading, spacing: 2) {
            Text(backdrop.strength.consequence)
            Text("About \(shown)% of the picture shows through with this theme.")
                .foregroundStyle(.secondary)
        }
        .font(.footnote)
        .accessibilityIdentifier("backdrop-measured")
    }

    private var replaceButton: some View {
        PhotosPicker(selection: $picked, matching: .images, photoLibrary: .shared()) {
            Label("Choose a Different Picture…", systemImage: "photo.on.rectangle")
        }
        .accessibilityIdentifier("backdrop-replace")
        .disabled(isWorking)
    }

    // MARK: - State

    private var currentBackground: RGBColor {
        container.settings.theme(for: true, hostOverride: nil).background
    }

    private var suppression: String? {
        guard container.settings.backdrop != nil else { return nil }
        return BackdropResolver().suppressionReason(
            reduceTransparency: reduceTransparency,
            increaseContrast: colorSchemeContrast == .increased,
            differentiateWithoutColor: differentiateWithoutColor
        )
    }

    private func change(_ backdrop: Backdrop, _ edit: (inout Backdrop) -> Void) {
        var updated = backdrop
        edit(&updated)
        container.settings.backdrop = updated
        container.grounds.invalidate()
    }

    private func importPicked() async {
        guard let picked else { return }
        isWorking = true
        defer { isWorking = false; self.picked = nil }
        do {
            guard let data = try await picked.loadTransferable(type: Data.self) else { return }
            let existing = container.settings.backdrop
            let backdrop = try container.backdrops.store(
                data: data,
                softness: existing?.softness ?? 0,
                strength: existing?.strength ?? .balanced,
                placement: existing?.placement ?? .fill
            )
            if let existing { container.backdrops.remove(existing.id) }
            container.settings.backdrop = backdrop
            container.grounds.invalidate()
            problem = nil
        } catch {
            problem = (error as? STError)?.message ?? String(localized: "That picture could not be used.")
        }
    }

    private func resoften(_ backdrop: Backdrop, to softness: Double) async {
        guard abs(backdrop.softness - softness) > 0.001 else { return }
        do {
            container.settings.backdrop = try container.backdrops.resoften(backdrop, softness: softness)
            container.grounds.invalidate()
        } catch {
            problem = (error as? STError)?.message ?? String(localized: "That picture could not be used.")
        }
    }

    private func remove(_ backdrop: Backdrop) {
        container.backdrops.remove(backdrop.id)
        container.settings.backdrop = nil
        container.grounds.invalidate()
    }
}
