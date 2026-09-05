import SwiftUI

/// The assistant's provider: an OpenAI-compatible endpoint, a model name, and a key kept
/// in the Keychain and shown only as "stored" (D-020).
struct AssistantSettingsSection: View {
    @Environment(AppContainer.self) private var container
    @State private var key = ""
    @State private var hasStoredKey = false
    @State private var prefersOnDevice = true
    @State private var endpoint = ""
    @State private var model = ""

    var body: some View {
        Section {
            #if canImport(FoundationModels)
            if #available(iOS 26, *) {
                Toggle("Prefer the on-device model", isOn: $prefersOnDevice)
                    .onChange(of: prefersOnDevice) { _, new in container.settings.assistantPrefersOnDevice = new }
            }
            #endif
            TextField("Provider base URL", text: $endpoint)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("assistant-endpoint")
                .onChange(of: endpoint) { _, new in container.settings.assistantEndpoint = new }
            TextField("Model", text: $model)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("assistant-model")
                .onChange(of: model) { _, new in container.settings.assistantModel = new }
            SecureField(hasStoredKey ? "API key (stored — enter to replace)" : "API key", text: $key)
                .textContentType(.oneTimeCode)
                .accessibilityIdentifier("assistant-key")
                .onSubmit(saveKey)
            if !key.isEmpty {
                Button("Save key", action: saveKey)
            }
            if hasStoredKey {
                Button("Remove key", role: .destructive) {
                    try? container.vault.deleteAssistantKey()
                    hasStoredKey = false
                    key = ""
                }
            }
        } header: {
            Text("Assistant")
        } footer: {
            Text(footer)
        }
        .onAppear {
            prefersOnDevice = container.settings.assistantPrefersOnDevice
            endpoint = container.settings.assistantEndpoint
            model = container.settings.assistantModel
            hasStoredKey = (try? container.vault.loadAssistantKey()) != nil
        }
    }

    private var footer: String {
        switch container.assistant.availability {
        case .onDevice:
            String(localized: "Answers come from Apple Intelligence on this device. A provider is used only if the on-device model is turned off or unavailable.")
        case let .provider(name):
            String(localized: "Answers come from \(name). The key stays in the Keychain on this device; only the text shown in the assistant is sent.")
        case let .unavailable(reason):
            reason
        }
    }

    private func saveKey() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? container.vault.storeAssistantKey(trimmed)
        hasStoredKey = true
        key = ""
    }
}
