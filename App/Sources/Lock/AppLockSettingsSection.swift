import SwiftUI

/// Settings for the app lock (D-023): on or off, Face ID or Touch ID in front of the
/// passcode, and how long the app may be away before it locks.
struct AppLockSettingsSection: View {
    @Environment(AppContainer.self) private var container
    @State private var sheet: PasscodeSheet?

    private var lock: AppLock { container.appLock }

    var body: some View {
        @Bindable var settings = container.settings

        Section {
            Toggle("Require a passcode to open", isOn: enabledBinding)
                .accessibilityIdentifier("applock-enabled")
                // On the row, not the section: a sheet attached to a Section inside a Form
                // is not presented.
                .sheet(item: $sheet) { mode in
                    PasscodeSheetView(mode: mode, lock: lock)
                }
            if lock.isEnabled {
                if lock.biometryKind != .none {
                    Toggle(String(localized: "Unlock with \(lock.biometryKind.title)"), isOn: $settings.appLockUsesBiometrics)
                        .accessibilityIdentifier("applock-biometrics")
                }
                Picker("Lock after leaving the app", selection: $settings.appLockGraceSeconds) {
                    ForEach(AppLockGrace.allCases) { grace in
                        Text(grace.title).tag(grace.rawValue)
                    }
                }
                .accessibilityIdentifier("applock-grace")
                Button("Change Passcode…") { sheet = .change }
                    .accessibilityIdentifier("applock-change")
            }
        } header: {
            Text("App lock")
        } footer: {
            if lock.isEnabled {
                Text("The passcode is the app's own, separate from the device passcode. It is never stored — only a salted derivation of it, on this device. Wrong guesses are slowed down, never punished by deleting anything.")
            } else {
                Text("Ask for a passcode — and Face ID or Touch ID, if you allow it — before the app shows your connections, keys and sessions.")
            }
        }
    }

    /// Reads the real state, so a cancelled sheet leaves the switch where it was.
    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { lock.isEnabled },
            set: { wantsOn in sheet = wantsOn ? .enable : .disable }
        )
    }
}

enum PasscodeSheet: String, Identifiable {
    case enable, change, disable
    var id: String { rawValue }
}

/// Sets, changes or removes the passcode. Every path that touches the passcode asks for
/// the current one first — Settings being open is not proof the owner is holding the device.
struct PasscodeSheetView: View {
    let mode: PasscodeSheet
    let lock: AppLock

    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var new = ""
    @State private var confirmation = ""
    @State private var problem: String?
    @FocusState private var focus: Field?

    private enum Field { case current, new, confirmation }

    var body: some View {
        NavigationStack {
            Form {
                if mode != .enable {
                    Section {
                        SecureField("Current passcode", text: $current)
                            .textContentType(.oneTimeCode)
                            .focused($focus, equals: .current)
                            .accessibilityIdentifier("applock-current")
                    } footer: {
                        if mode == .disable {
                            Text("Turning the lock off removes the passcode. Your connections and keys stay.")
                        }
                    }
                }
                if mode != .disable {
                    Section {
                        SecureField("New passcode", text: $new)
                            .textContentType(.oneTimeCode)
                            .focused($focus, equals: .new)
                            .accessibilityIdentifier("applock-new")
                        SecureField("Confirm passcode", text: $confirmation)
                            .textContentType(.oneTimeCode)
                            .focused($focus, equals: .confirmation)
                            .submitLabel(.done)
                            .onSubmit(save)
                            .accessibilityIdentifier("applock-confirm")
                    } footer: {
                        Text("At least \(PasscodePolicy.minimumLength) characters. Letters, numbers and symbols are all allowed.")
                    }
                }
                if let problem {
                    Section {
                        Label(problem, systemImage: "exclamationmark.circle")
                            .foregroundStyle(DesignTokens.Color.danger)
                            .accessibilityIdentifier("applock-problem")
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(mode == .disable ? String(localized: "Turn Off") : String(localized: "Save")) { save() }
                        .disabled(!canSave)
                        .accessibilityIdentifier("applock-save")
                }
            }
            .onAppear { focus = mode == .enable ? .new : .current }
        }
        .interactiveDismissDisabled(false)
    }

    private var title: String {
        switch mode {
        case .enable: String(localized: "Set a Passcode")
        case .change: String(localized: "Change Passcode")
        case .disable: String(localized: "Turn Off App Lock")
        }
    }

    private var canSave: Bool {
        switch mode {
        case .enable: !new.isEmpty && !confirmation.isEmpty
        case .change: !current.isEmpty && !new.isEmpty && !confirmation.isEmpty
        case .disable: !current.isEmpty
        }
    }

    private func save() {
        guard canSave else { return }
        if mode != .enable, !lock.confirmIdentity(passcode: current) {
            problem = String(localized: "The current passcode is not right.")
            current = ""
            focus = .current
            return
        }
        if mode != .disable, new != confirmation {
            problem = String(localized: "The two entries do not match.")
            confirmation = ""
            focus = .confirmation
            return
        }
        do {
            switch mode {
            case .enable: try lock.enable(passcode: new)
            case .change: try lock.changePasscode(to: new)
            case .disable: lock.disable()
            }
            dismiss()
        } catch {
            problem = error.localizedDescription
            focus = .new
        }
    }
}
