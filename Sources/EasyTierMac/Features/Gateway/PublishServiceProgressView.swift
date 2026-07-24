import SwiftUI

struct PublishServiceProgressView: View {
    let serviceURL: String
    let presentation: PublishServiceProgressPresentation
    let isRetrying: Bool
    let onClose: () -> Void
    let onRetry: () -> Void

    private var statusStyle: Color {
        switch presentation.phase {
        case .https: .green
        case .httpOnly, .waitingRetry, .failed: .orange
        case .requesting: .secondary
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                if presentation.showsProgress {
                    ProgressView()
                        .controlSize(.large)
                        .accessibilityLabel(presentation.title)
                } else {
                    Image(systemName: presentation.systemImage)
                        .font(.title)
                        .foregroundStyle(statusStyle)
                        .accessibilityHidden(true)
                }

                VStack(spacing: 4) {
                    Text(presentation.title)
                        .font(.headline)
                    Text(presentation.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(serviceURL)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if presentation.phase == .requesting {
                    Text("Certificate issuance continues if you close this window.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)

            Divider()

            HStack {
                Spacer(minLength: 0)
                if presentation.phase != .https {
                    Button("Close", role: .cancel, action: onClose)
                        .keyboardShortcut(.cancelAction)
                }
                if presentation.canRetry {
                    Button(action: onRetry) {
                        HStack {
                            if isRetrying {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(isRetrying ? "Retrying…" : "Retry Certificate")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRetrying)
                    .keyboardShortcut(.defaultAction)
                } else if presentation.phase == .https {
                    Button("Done", action: onClose)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }
}
