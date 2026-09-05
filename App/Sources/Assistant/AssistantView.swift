import SwiftUI

/// The assistant sheet (D-020): pick what to ask, see exactly what will be sent, ask,
/// and take a suggested command onto the prompt — never run.
struct AssistantView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    let session: TerminalSession

    @State private var task: AssistantTask = .howTo
    @State private var source: AssistantContextSource = .none
    @State private var question = ""
    @State private var showsSettings = false

    private var assistant: AssistantCoordinator { container.assistant }
    private var availability: AssistantAvailability { assistant.availability }

    /// For automated runs: which engine the sheet is showing.
    private var engineName: String {
        switch availability {
        case .onDevice: "onDevice"
        case .provider: "provider"
        case .unavailable: "unavailable"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if case let .unavailable(reason) = availability {
                    Section {
                        Label(reason, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(DesignTokens.Color.labelSecondary)
                            // One element whose label is the reason, not an icon called "Warning".
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(reason)
                            .accessibilityIdentifier("assistant-unavailable")
                        Button("Open Settings") { showsSettings = true }
                    } header: {
                        Text("Nothing can answer yet")
                    }
                } else {
                    askSection
                    contextSection
                    answerSection
                }
            }
            .navigationTitle("Assistant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { assistant.cancel(); dismiss() }
                }
            }
            .sheet(isPresented: $showsSettings) { SettingsView() }
            .accessibilityIdentifier("assistant-sheet")
            .accessibilityValue(engineName)
        }
        .onAppear {
            if session.selectedText != nil { source = .selection } else if task != .howTo { source = .screen }
        }
    }

    private var askSection: some View {
        Section {
            Picker("Kind", selection: $task) {
                ForEach(AssistantTask.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: task) { _, new in
                if new != .howTo, source == .none { source = session.selectedText != nil ? .selection : .screen }
            }
            TextField(task.prompt, text: $question, axis: .vertical)
                .lineLimit(1 ... 4)
                .accessibilityIdentifier("assistant-question")
                .textContentType(.oneTimeCode)
            Button {
                assistant.ask(task: task, question: question, context: context)
            } label: {
                if assistant.isBusy {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("Ask").frame(maxWidth: .infinity)
                }
            }
            .disabled(assistant.isBusy || (question.trimmingCharacters(in: .whitespaces).isEmpty && context.terminalText == nil))
            .accessibilityIdentifier("assistant-ask")
        } footer: {
            switch availability {
            case .onDevice:
                Text("Answered on this device by Apple Intelligence. Nothing leaves the device.")
            case let .provider(name):
                Text("Sent to \(name). Only the text shown here is sent: the question, the server's platform, the last command, and the terminal text you chose.")
            case .unavailable:
                EmptyView()
            }
        }
    }

    private var contextSection: some View {
        Section {
            Picker("Include", selection: $source) {
                ForEach(AssistantContextSource.allCases) { candidate in
                    if candidate != .selection || session.selectedText != nil {
                        Text(candidate.title).tag(candidate)
                    }
                }
            }
            if let text = context.terminalText {
                Text(text)
                    .font(DesignTokens.Typography.monoCaption)
                    .lineLimit(8)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("assistant-context")
            }
        } header: {
            Text("Terminal text to send")
        } footer: {
            Text("Terminal text can contain secrets. Look before you send.")
        }
    }

    @ViewBuilder private var answerSection: some View {
        if let error = assistant.error {
            Section("Answer") {
                Label(error, systemImage: "xmark.octagon")
                    .foregroundStyle(DesignTokens.Color.danger)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(error)
                    .accessibilityIdentifier("assistant-error")
            }
        } else if !assistant.answer.isEmpty {
            Section("Answer") {
                Text(assistant.answer)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("assistant-answer")
            }
            if !assistant.reply.commands.isEmpty {
                Section {
                    ForEach(assistant.reply.commands, id: \.self) { command in
                        HStack {
                            Text(command)
                                .font(DesignTokens.Typography.monoCaption)
                                .lineLimit(2)
                            Spacer()
                            Button("Insert") {
                                Task { await session.insert(commandText: command) }
                                dismiss()
                            }
                            .buttonStyle(.borderedProminent)
                            Button("Copy", systemImage: "doc.on.doc") {
                                Clipboard.copy(command, expiringAfter: container.settings.clipboardExpirySeconds)
                            }
                            .labelStyle(.iconOnly)
                        }
                    }
                } header: {
                    Text("Suggested commands")
                } footer: {
                    Text("Insert puts the command on the prompt without running it.")
                }
            }
        }
    }

    private var context: AssistantContext {
        var context = AssistantContext(platform: session.host.effectivePlatform, lastCommand: session.lastSubmittedCommand)
        context.source = source
        switch source {
        case .selection: context.terminalText = session.selectedText
        case .screen: context.terminalText = session.screenText
        case .none: context.terminalText = nil
        }
        if context.terminalText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { context.terminalText = nil }
        return context
    }
}
