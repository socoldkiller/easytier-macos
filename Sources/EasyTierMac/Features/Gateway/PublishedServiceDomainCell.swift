import SwiftUI

struct PublishedServiceDomainCell: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var row: PublishedServiceTableRow
    var isWorking: Bool
    var onOpen: (PublishedServiceTableRow) -> Void
    @State private var isHovered = false

    var body: some View {
        Button {
            onOpen(row)
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    if showsProgress, !reduceMotion {
                        ProgressView()
                            .controlSize(.mini)
                    } else if showsProgress {
                        Image(systemName: "hourglass")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 7, height: 7)
                    }
                }
                .frame(width: 12, height: 12)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(row.publicHostname)
                        .font(.callout)
                        .foregroundStyle(isHovered ? Color.accentColor : Color.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(statusSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .workspaceDataGridTwoLineContent()
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .pointingHandOnHover()
        .onHover { isHovered = $0 }
        .help(helpText)
        .accessibilityLabel(Text("\(row.publicHostname), \(statusSummary)"))
        .accessibilityHint(Text("Opens the public service in the default browser"))
    }

    private var statusLabel: String {
        isWorking ? "Updating" : row.presentation.statusLabel
    }

    private var statusDetail: String {
        if isWorking { return "Applying changes" }
        return row.presentation.errorMessage ?? row.presentation.detailLabel
    }

    private var statusSummary: String {
        "\(statusLabel) · \(statusDetail)"
    }

    private var showsProgress: Bool {
        isWorking || row.presentation.isInProgress
    }

    private var helpText: String {
        "Open \(row.publicURL?.absoluteString ?? row.publicHostname)\nStatus: \(statusSummary)"
    }

    private var statusColor: Color {
        switch row.presentation.tone {
        case .neutral: .secondary
        case .positive: EasyTierColors.statusConnected
        case .warning: .orange
        }
    }
}
