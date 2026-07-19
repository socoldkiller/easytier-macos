import EasyTierShared
import SwiftUI

struct PublishedServiceRow: View {
    let service: GatewayPublishedService
    let presentation: PublishedServicePresentation
    let isWorking: Bool
    let onSetEnabled: (Bool) -> Void
    let onEditPort: () -> Void
    let onRetryCertificate: () -> Void
    let onOpen: () -> Void
    let onCopyHostname: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(service.publicHostname)
                        .font(.headline.monospaced())
                        .lineLimit(1)
                        .textSelection(.enabled)
                    Text("HTTP · \(service.targetDomain):\(service.targetPort)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 10)

                StatusPill(
                    presentation.statusLabel,
                    tone: presentation.tone.statusPillTone
                )

                Toggle("Enabled", isOn: enabledBinding)
                    .labelsHidden()
                    .disabled(isWorking || !presentation.canToggleEnabled)
                    .help(service.desiredEnabled ? "Disable this service" : "Enable this service")

                Button("Open", systemImage: "safari", action: onOpen)
                    .disabled(isWorking || !presentation.canOpen)

                Menu("More", systemImage: "ellipsis.circle") {
                    Button("Copy Hostname", systemImage: "doc.on.doc", action: onCopyHostname)
                    Button("Edit Port…", systemImage: "pencil", action: onEditPort)
                        .disabled(isWorking)
                    Button(
                        presentation.certificateActionTitle,
                        systemImage: "arrow.clockwise",
                        action: onRetryCertificate
                    )
                    .disabled(isWorking || !presentation.canRetryCertificate)
                    Divider()
                    Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                        .disabled(isWorking)
                }
            }
            .controlSize(.small)

            if let errorMessage = presentation.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(errorMessage)
            }
        }
        .padding(.vertical, 9)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { service.desiredEnabled },
            set: { enabled in
                guard enabled != service.desiredEnabled else { return }
                onSetEnabled(enabled)
            }
        )
    }
}
