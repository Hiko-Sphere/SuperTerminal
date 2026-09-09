import Foundation
import Observation
import STCore

/// Chooses the engine, runs a request, and holds the answer for the view (D-020).
///
/// The choice is made fresh for every request from what is true then: the on-device
/// model where the device is eligible and the user has not turned it off, otherwise the
/// provider the user configured, otherwise nothing — and "nothing" is said plainly.
@Observable
@MainActor
final class AssistantCoordinator {
    private let settings: AppSettings
    private let vault: CredentialVault
    private let log: STLogger

    private(set) var answer = ""
    private(set) var reply = AssistantReply.empty
    private(set) var isBusy = false
    private(set) var error: String?
    /// Why the on-device model last failed, if it did. Until the app restarts the model
    /// is treated as unavailable for that reason: a device that says the model is there
    /// and then cannot run it — the simulator on this Mac does exactly that — would
    /// otherwise fail the same way on every question.
    private(set) var onDeviceFailure: String?
    private var current: Task<Void, Never>?

    init(settings: AppSettings, vault: CredentialVault, log: STLogger) {
        self.settings = settings
        self.vault = vault
        self.log = log
    }

    /// What would answer right now, and why nothing would.
    var availability: AssistantAvailability {
        if onDeviceEngine() != nil { return .onDevice }
        if let provider = providerEngine() { return .provider(name: provider.displayName) }
        return .unavailable(reason: unavailabilityReason)
    }

    private var unavailabilityReason: String {
        var reasons: [String] = []
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            if !settings.assistantPrefersOnDevice {
                reasons.append(String(localized: "The on-device model is turned off in Settings."))
            } else if let onDeviceFailure {
                reasons.append(String(localized: "The on-device model failed: \(onDeviceFailure)"))
            } else if let reason = OnDeviceAssistant.unavailabilityReason {
                reasons.append(reason)
            }
        } else {
            reasons.append(String(localized: "The on-device model needs iOS 26."))
        }
        #else
        reasons.append(String(localized: "The on-device model is not part of this build."))
        #endif
        if providerConfiguration == nil {
            reasons.append(String(localized: "No provider is configured in Settings."))
        } else if (try? vault.loadAssistantKey()) == nil {
            reasons.append(String(localized: "The configured provider has no API key stored."))
        }
        return reasons.joined(separator: " ")
    }

    var providerConfiguration: ProviderAssistant.Configuration? {
        guard let url = URL(string: settings.assistantEndpoint), url.scheme == "https" || url.host() == "127.0.0.1" || url.host() == "localhost",
              !settings.assistantModel.isEmpty else { return nil }
        return ProviderAssistant.Configuration(baseURL: url, model: settings.assistantModel)
    }

    private func onDeviceEngine() -> (any AssistantEngine)? {
        #if canImport(FoundationModels)
        if #available(iOS 26, *), settings.assistantPrefersOnDevice, onDeviceFailure == nil, OnDeviceAssistant.isAvailable {
            return OnDeviceAssistant()
        }
        #endif
        return nil
    }

    private func providerEngine() -> ProviderAssistant? {
        guard let configuration = providerConfiguration, (try? vault.loadAssistantKey()) != nil else { return nil }
        let vault = self.vault
        return ProviderAssistant(configuration: configuration, keyProvider: { try vault.loadAssistantKey() })
    }

    func ask(task: AssistantTask, question: String, context: AssistantContext) {
        current?.cancel()
        answer = ""
        reply = .empty
        error = nil
        guard let engine = onDeviceEngine() ?? providerEngine() else {
            error = unavailabilityReason
            return
        }
        let prompt = AssistantPromptBuilder.build(task: task, question: question, context: context)
        isBusy = true
        let labels = ["task": task.rawValue, "context": context.source.rawValue]
        current = Task { [weak self] in
            await self?.run(prompt, on: engine, labels: labels)
        }
    }

    /// Streams one answer. An on-device failure is remembered, and the provider — if the
    /// user configured one — answers the same question instead.
    private func run(_ prompt: AssistantPrompt, on engine: any AssistantEngine, labels: [String: String]) async {
        let onDevice = !(engine is ProviderAssistant)
        log.info("assistant request", labels.merging(["engine": onDevice ? "onDevice" : "provider"]) { $1 })
        do {
            for try await delta in engine.respond(to: prompt) {
                guard !Task.isCancelled else { return }
                answer += delta
            }
            reply = AssistantReplyParser.parse(answer)
        } catch {
            guard !Task.isCancelled else { return }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if onDevice, case let AssistantError.onDevice(reason) = error {
                onDeviceFailure = reason
                log.error("on-device assistant failed", ["category": "assistant"])
                if let provider = providerEngine() {
                    answer = ""
                    await run(prompt, on: provider, labels: labels)
                    return
                }
            } else {
                log.error("assistant request failed", ["category": "assistant"])
            }
            self.error = message
        }
        isBusy = false
    }

    func cancel() {
        current?.cancel()
        current = nil
        isBusy = false
    }
}
