import SwiftUI

/// Editing a file's mode (D-043).
///
/// Nine checkboxes and the octal together, because the two audiences for this screen are
/// different people: someone who knows `chmod 644` wants to type it, and someone who does
/// not wants to see that "group" cannot write. Each drives the other, so neither is a
/// second-class way in.
struct FilePermissionsView: View {
    @Environment(\.dismiss) private var dismiss
    let entry: SFTPEntry
    let apply: (UInt32) -> Void

    @State private var mode: UInt32
    @State private var octalText: String

    init(entry: SFTPEntry, apply: @escaping (UInt32) -> Void) {
        self.entry = entry
        self.apply = apply
        // Only the low twelve bits are the mode; the rest is the file type, which is not
        // the user's to change and must be preserved when the mode is written back.
        let permissions = (entry.attributes.permissions ?? 0o644) & 0o7777
        _mode = State(initialValue: permissions)
        _octalText = State(initialValue: String(permissions, radix: 8))
    }

    private struct Group: Identifiable {
        let id: String
        let name: LocalizedStringKey
        let shift: UInt32
    }

    private static let groups = [
        Group(id: "owner", name: "Owner", shift: 6),
        Group(id: "group", name: "Group", shift: 3),
        Group(id: "everyone", name: "Everyone", shift: 0),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(Self.groups) { group in
                        HStack {
                            Text(group.name).frame(width: 90, alignment: .leading)
                            Spacer()
                            ForEach(Array(["r", "w", "x"].enumerated()), id: \.offset) { index, letter in
                                toggle(letter: letter, bit: UInt32(4 >> index) << group.shift)
                            }
                        }
                    }
                } header: {
                    Text("Permissions")
                } footer: {
                    Text("Read, write and execute. On a folder, execute is what allows its contents to be listed at all.")
                }

                Section {
                    HStack {
                        Text("Octal")
                        Spacer()
                        TextField("644", text: $octalText)
                            .multilineTextAlignment(.trailing)
                            .font(DesignTokens.Typography.monoCaption)
                            .keyboardType(.numberPad)
                            .frame(width: 80)
                            .accessibilityIdentifier("permissions-octal")
                            .onChange(of: octalText) { _, new in
                                // Only a valid mode is taken; anything else leaves the
                                // checkboxes where they were rather than clearing them
                                // halfway through typing.
                                let digits = new.filter { "01234567".contains($0) }
                                if digits != new { octalText = digits }
                                if let value = UInt32(digits, radix: 8), value <= 0o7777 {
                                    mode = value
                                }
                            }
                    }
                    LabeledContent("As shown in a listing") {
                        Text(Self.symbolic(mode, isDirectory: entry.isDirectory))
                            .font(DesignTokens.Typography.monoCaption)
                    }
                } header: {
                    Text("Or type it")
                }
            }
            .navigationTitle(entry.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { apply(mode); dismiss() }
                        .accessibilityIdentifier("permissions-apply")
                }
            }
        }
    }

    private func toggle(letter: String, bit: UInt32) -> some View {
        Button {
            mode ^= bit
            octalText = String(mode, radix: 8)
        } label: {
            Text(letter)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .frame(width: 32, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                        .fill(mode & bit != 0 ? DesignTokens.Color.accent : DesignTokens.Color.surfaceSecondary)
                )
                .foregroundStyle(mode & bit != 0 ? Color.white : DesignTokens.Color.labelTertiary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(letter))
        .accessibilityValue(Text(mode & bit != 0 ? "On" : "Off"))
        .accessibilityAddTraits(mode & bit != 0 ? [.isSelected] : [])
    }

    static func symbolic(_ mode: UInt32, isDirectory: Bool) -> String {
        var result = isDirectory ? "d" : "-"
        for shift in stride(from: 6, through: 0, by: -3) {
            let group = (mode >> UInt32(shift)) & 0o7
            for (index, letter) in ["r", "w", "x"].enumerated() {
                result += (group & UInt32(4 >> index)) != 0 ? letter : "-"
            }
        }
        return result
    }
}
