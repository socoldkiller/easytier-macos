import EasyTierShared
import SwiftUI

struct PublishedServiceStatusCell: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var row: PublishedServiceTableRow
    var isWorking: Bool
    var actionsDisabled: Bool
    var onSetEnabled: (Bool, GatewayPublishedService) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                if showsProgress, !reduceMotion {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel(Text(progressAccessibilityLabel))
                } else if showsProgress {
                    Image(systemName: "hourglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text(progressAccessibilityLabel))
                } else {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 12, height: 12)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusLabel)
                    .lineLimit(1)
                Text(statusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Toggle(
                "\(row.publicHostname) enabled",
                isOn: Binding(
                    get: { row.service.desiredEnabled },
                    set: { enabled in
                        guard enabled != row.service.desiredEnabled else { return }
                        onSetEnabled(enabled, row.service)
                    }
                )
            )
            .labelsHidden()
            .disabled(actionsDisabled || !row.presentation.canToggleEnabled)
            .help(row.service.desiredEnabled ? "Disable this service" : "Enable this service")
        }
        .controlSize(.small)
        .help(statusHelp)
        .accessibilityElement(children: .contain)
    }

    private var statusLabel: String {
        isWorking ? "Updating" : row.presentation.statusLabel
    }

    private var statusDetail: String {
        if isWorking { return "Applying changes" }
        if let errorMessage = row.presentation.errorMessage { return errorMessage }
        return row.presentation.detailLabel
    }

    private var showsProgress: Bool {
        isWorking || row.presentation.isInProgress
    }

    private var progressAccessibilityLabel: String {
        "\(statusLabel) \(row.publicHostname): \(statusDetail)"
    }

    private var statusHelp: String {
        row.presentation.errorMessage ?? "\(statusLabel) · \(statusDetail)"
    }

    private var statusColor: Color {
        switch row.presentation.tone {
        case .neutral: .secondary
        case .positive: EasyTierColors.statusConnected
        case .warning: .orange
        }
    }
}
