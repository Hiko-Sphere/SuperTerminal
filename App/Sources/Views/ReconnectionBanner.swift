import STCore
import SwiftUI

/// A slim bar shown while a dropped session is being retried.
///
/// A bar rather than the blocking overlay used for a first connection, and deliberately
/// so: the scrollback behind it holds the command that was running when the link went and
/// what it had printed, which is exactly what the user wants to read while they wait.
/// Covering it with a modal would hide the only record of what happened.
struct ReconnectionBanner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let reconnection: TerminalSession.Reconnection
    let interface: NetworkReachability.Interface
    let onRetryNow: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            indicator

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(headline)
                    .font(DesignTokens.Typography.callout.weight(.medium))
                    .foregroundStyle(DesignTokens.Color.label)
                Text(detail)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Color.labelSecondary)
                    .monospacedDigit()
            }

            Spacer(minLength: DesignTokens.Spacing.sm)

            if !reconnection.isAttempting {
                Button("Retry now", action: onRetryNow)
                    .font(DesignTokens.Typography.caption.weight(.medium))
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            Button("Stop", action: onStop)
                .font(DesignTokens.Typography.caption)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .stBarBackground()
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(headline). \(detail)")
    }

    /// A spinner while an attempt is in flight, a steady dot while waiting.
    ///
    /// The difference matters: a spinner that never stops says nothing about whether
    /// anything is happening, and this bar can sit for half a minute between attempts.
    @ViewBuilder
    private var indicator: some View {
        if reconnection.isAttempting {
            ProgressView()
                .controlSize(.small)
        } else {
            Circle()
                .fill(reconnection.isWaitingForNetwork ? DesignTokens.Color.danger : DesignTokens.Color.warning)
                .frame(width: 8, height: 8)
                .modifier(BreathingOpacity(enabled: !reduceMotion))
        }
    }

    private var headline: String {
        if reconnection.isWaitingForNetwork {
            return "Waiting for a network"
        }
        if reconnection.isAttempting {
            return "Reconnecting…"
        }
        if reconnection.nextAttempt == nil {
            return "Could not reconnect"
        }
        return "Connection lost"
    }

    private var detail: String {
        if reconnection.isWaitingForNetwork {
            return "\(interface.rawValue). Will retry as soon as there is one."
        }
        if reconnection.isAttempting {
            return "Attempt \(reconnection.attempt)"
        }
        guard let next = reconnection.nextAttempt else {
            return reconnection.lastError.message
        }
        return CountdownText.phrase(until: next, attempt: reconnection.attempt)
    }
}

/// The countdown, recomputed on a timeline rather than by a stored timer.
///
/// `TimelineView` only redraws this one line, which matters in a terminal: a timer that
/// invalidated the whole view would redraw the grid once a second for as long as the
/// connection stayed down.
private enum CountdownText {
    static func phrase(until date: Date, attempt: Int) -> String {
        let remaining = max(0, Int(date.timeIntervalSinceNow.rounded(.up)))
        if remaining <= 0 { return "Attempt \(attempt + 1) starting" }
        return "Attempt \(attempt) failed · retrying in \(remaining)s"
    }
}

/// A slow pulse, so a waiting indicator reads as alive rather than stuck.
private struct BreathingOpacity: ViewModifier {
    let enabled: Bool
    @State private var dimmed = false

    func body(content: Content) -> some View {
        content
            .opacity(enabled && dimmed ? 0.35 : 1)
            .animation(
                enabled ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true) : nil,
                value: dimmed
            )
            .onAppear { if enabled { dimmed = true } }
    }
}
