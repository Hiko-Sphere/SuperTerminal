import SwiftUI

/// What is moving, how fast, and how much longer (D-042).
///
/// Its own screen rather than a banner: a transfer can outlive the folder it started
/// from, and a progress bar that disappears when you navigate is worse than none.
struct TransferQueueView: View {
    @Environment(\.dismiss) private var dismiss
    let session: SFTPSession

    var body: some View {
        NavigationStack {
            List {
                ForEach(session.transfers) { transfer in
                    row(transfer)
                }
            }
            .overlay {
                if session.transfers.isEmpty {
                    ContentUnavailableView("No transfers", systemImage: "arrow.up.arrow.down")
                }
            }
            .navigationTitle("Transfers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear finished") { session.clearFinishedTransfers() }
                        .disabled(!session.transfers.contains { $0.state.isTerminal })
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ transfer: FileTransfer) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: transfer.direction == .upload ? "arrow.up.circle" : "arrow.down.circle")
                    .foregroundStyle(DesignTokens.Color.accent)
                Text(transfer.name).font(DesignTokens.Typography.body).lineLimit(1)
                Spacer()
                controls(transfer)
            }
            if case .running = transfer.state {
                ProgressView(value: transfer.fraction ?? 0)
                    .progressViewStyle(.linear)
            }
            Text(detail(transfer))
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(colour(transfer))
        }
        .padding(.vertical, DesignTokens.Spacing.xxs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(transfer.name), \(detail(transfer))"))
    }

    @ViewBuilder
    private func controls(_ transfer: FileTransfer) -> some View {
        switch transfer.state {
        case .running:
            Button("Pause", systemImage: "pause.circle") { transfer.pause() }
                .labelStyle(.iconOnly)
            Button("Cancel", systemImage: "xmark.circle") { transfer.cancel() }
                .labelStyle(.iconOnly)
        case .paused:
            Button("Resume", systemImage: "play.circle") { transfer.resume() }
                .labelStyle(.iconOnly)
        case .failed:
            Button("Retry", systemImage: "arrow.clockwise") { session.retry(transfer) }
                .labelStyle(.iconOnly)
        case .waiting, .finished, .cancelled:
            EmptyView()
        }
    }

    private func detail(_ transfer: FileTransfer) -> String {
        switch transfer.state {
        case .waiting: String(localized: "Waiting")
        case .paused: String(localized: "Paused — \(transfer.formattedProgress)")
        case .finished: String(localized: "Finished — \(transfer.formattedProgress)")
        case .cancelled: String(localized: "Cancelled")
        case let .failed(reason): reason
        case .running:
            if let rate = transfer.formattedRate, let remaining = transfer.secondsRemaining {
                String(localized: "\(transfer.formattedProgress) · \(rate) · \(Self.remaining(remaining)) left")
            } else if let rate = transfer.formattedRate {
                String(localized: "\(transfer.formattedProgress) · \(rate)")
            } else {
                transfer.formattedProgress
            }
        }
    }

    private func colour(_ transfer: FileTransfer) -> Color {
        switch transfer.state {
        case .failed: DesignTokens.Color.danger
        case .finished: DesignTokens.Color.success
        default: DesignTokens.Color.labelSecondary
        }
    }

    private static func remaining(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds < 60 ? [.second] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? ""
    }
}
