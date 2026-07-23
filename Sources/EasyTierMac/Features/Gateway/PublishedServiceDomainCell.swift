import SwiftUI

struct PublishedServiceDomainCell: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.windowPresentationActivity) private var presentationActivity

    var row: PublishedServiceTableRow
    var isWorking: Bool
    var onOpen: (PublishedServiceTableRow) -> Void
    @State private var isHovered = false
    @State private var transientFeedback: PublishedServiceStatusFeedback?

    var body: some View {
        Button {
            onOpen(row)
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    statusGlyph
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
        .onChange(of: feedbackObservation) { oldValue, newValue in
            guard let feedback = newValue.transition(from: oldValue) else { return }
            setTransientFeedback(feedback)
        }
        .task(id: transientFeedback) {
            guard transientFeedback != nil else { return }
            try? await Task.sleep(for: .milliseconds(1_400))
            guard !Task.isCancelled else { return }
            setTransientFeedback(nil)
        }
    }

    @ViewBuilder
    private var statusGlyph: some View {
        if let transientFeedback {
            feedbackIcon(transientFeedback)
                .transition(reduceMotion ? .opacity : .scale(scale: 0.7).combined(with: .opacity))
        } else if showsProgress, presentationActivity.allowsAnimations, !reduceMotion {
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

    @ViewBuilder
    private func feedbackIcon(_ feedback: PublishedServiceStatusFeedback) -> some View {
        switch feedback {
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(EasyTierColors.statusConnected)
                .symbolEffect(.bounce, value: transientFeedback)
        case .failure:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .symbolEffect(.wiggle, value: transientFeedback)
        case .none:
            EmptyView()
        }
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

    private var feedbackObservation: PublishedServiceStatusFeedbackObservation {
        PublishedServiceStatusFeedbackObservation(
            feedback: PublishedServiceStatusFeedback(presentation: row.presentation),
            isWindowInteractive: presentationActivity.allowsAnimations
        )
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

    private func setTransientFeedback(_ feedback: PublishedServiceStatusFeedback?) {
        if reduceMotion {
            transientFeedback = feedback
        } else {
            withAnimation(EasyTierMotion.selection(reduceMotion: false)) {
                transientFeedback = feedback
            }
        }
    }
}
