import STCloudflare
import STCore
import SwiftUI

/// Says what is actually true about one Cloudflare Access hostname (D-053).
///
/// Everything here is measured when the screen runs, against the real hostname. Nothing is
/// inferred from what was saved: the whole reason a connection through Access fails is
/// usually that the world disagrees with the record — the application was renamed, the
/// policy changed, the token expired, the hostname is not behind Access at all — and a
/// screen that repeated the record back would be no help with any of that.
struct AccessDiagnosticsView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss

    let host: Host

    @State private var steps: [Step] = []
    @State private var running = false
    @State private var appInfo: AccessAppInfo?

    /// One thing that was checked, and what came back.
    struct Step: Identifiable {
        enum Outcome {
            case good(String)
            case warning(String)
            case bad(String)
        }

        let id = UUID()
        let title: String
        let outcome: Outcome
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Hostname", value: host.hostname)
                    LabeledContent("Port", value: String(host.port))
                    LabeledContent(
                        "Sign-in",
                        value: host.accessAuthentication == .serviceToken
                            ? String(localized: "Service token")
                            : String(localized: "Browser")
                    )
                } header: {
                    Text("What is configured")
                }

                if running, steps.isEmpty {
                    Section {
                        HStack(spacing: DesignTokens.Spacing.md) {
                            ProgressView()
                            Text("Checking…")
                                .foregroundStyle(DesignTokens.Color.labelSecondary)
                        }
                    }
                }

                if !steps.isEmpty {
                    Section {
                        ForEach(steps) { step in
                            StepRow(step: step)
                        }
                    } header: {
                        Text("What was found")
                    } footer: {
                        Text("Checked just now, against the hostname itself.")
                    }
                }

                if let appInfo {
                    Section {
                        Button("Sign out of this application", role: .destructive) {
                            try? container.vault.deleteAccessToken(appIdentifier: appInfo.storageIdentifier)
                            Task { await run() }
                        }
                        .accessibilityIdentifier("access-sign-out-app")
                    } footer: {
                        // Per application, not globally: someone with two organisations
                        // should be able to sign out of one without losing the other.
                        Text("Signs out of \(appInfo.appHostname) only. Other Cloudflare Access applications keep their sessions.")
                    }
                }
            }
            .navigationTitle("Access Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Check again") { Task { await run() } }
                        .disabled(running)
                        .accessibilityIdentifier("access-recheck")
                }
            }
            .task { await run() }
        }
    }

    /// Runs the checks in the order a connection would, so the first failure here is the
    /// first failure a connection would hit.
    ///
    /// Only the I/O lives here. What each result *means* is `AccessDiagnostics`, which is
    /// a pure function over what came back and therefore has tests: the reasoning is the
    /// part that can be wrong in a way nobody notices.
    private func run() async {
        running = true
        steps = []
        appInfo = nil
        defer { running = false }

        let http = URLSessionHTTPTransport(userAgent: AccessCredentialResolver.userAgent)
        let jwks = JWKSProvider(http: http)
        let discovery = AccessDiscovery(http: http, jwks: jwks, log: container.diagnostics.logger)

        let probe: AccessDiscovery.Probe
        do {
            probe = try await discovery.probe(host: host.hostname, port: host.port)
        } catch {
            steps = AccessDiagnostics.steps(unreachable: (error as? STError)?.message)
            return
        }

        guard case let .protected(info) = probe else {
            steps = AccessDiagnostics.steps(for: probe, session: .notApplicable)
            return
        }
        appInfo = info

        let session: AccessDiagnostics.SessionState
        if host.accessAuthentication == .serviceToken {
            session = container.vault.hasServiceToken(hostID: host.id) ? .serviceTokenStored : .serviceTokenMissing
        } else if let stored = (try? container.vault.loadAccessToken(appIdentifier: info.storageIdentifier)) ?? nil {
            let validator = AccessTokenValidator(jwks: jwks)
            do {
                let token = try await validator.validate(rawToken: stored, appInfo: info)
                session = token.isExpired() ? .expired : .valid(until: token.expiresAt)
            } catch {
                session = .unusable
            }
        } else {
            session = .notSignedIn
        }

        steps = AccessDiagnostics.steps(for: probe, session: session)
    }
}

private struct StepRow: View {
    let step: AccessDiagnosticsView.Step

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.md) {
            Image(systemName: symbol)
                .foregroundStyle(colour)
                // The icon is not the only carrier of the result: the text says it too,
                // which is what "differentiate without colour" asks for.
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(step.title)
                    .font(DesignTokens.Typography.body)
                Text(detail)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(step.title). \(accessibilityOutcome). \(detail)")
    }

    private var detail: String {
        switch step.outcome {
        case let .good(text), let .warning(text), let .bad(text): text
        }
    }

    private var accessibilityOutcome: String {
        switch step.outcome {
        case .good: String(localized: "OK")
        case .warning: String(localized: "Needs attention")
        case .bad: String(localized: "Problem")
        }
    }

    private var symbol: String {
        switch step.outcome {
        case .good: "checkmark.circle"
        case .warning: "exclamationmark.triangle"
        case .bad: "xmark.circle"
        }
    }

    private var colour: Color {
        switch step.outcome {
        case .good: DesignTokens.Color.success
        case .warning: DesignTokens.Color.warning
        case .bad: DesignTokens.Color.danger
        }
    }
}
