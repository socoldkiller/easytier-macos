import EasyTierShared
import SwiftUI

struct GatewayCertificatesSettingsSection: View {
    let gateway: GatewayRuntimeController

    private var statusByID: [String: GatewayCertificateStatus] {
        Dictionary(uniqueKeysWithValues: gateway.status.certificates.map { ($0.id, $0) })
    }

    var body: some View {
        CardSection(
            "Certificates",
            systemImage: "checkmark.shield",
            footer: "Automatic wildcard certificates are shared by services on the same node."
        ) {
            if gateway.certificates.isEmpty {
                Text("No certificates")
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("Domain")
                        Text("Status")
                        Text("Expiration")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    SettingsRowDivider()
                        .gridCellColumns(3)

                    ForEach(gateway.certificates) { certificate in
                        let status = statusByID[certificate.id]
                        GridRow {
                            Text(certificate.domains.first ?? "—")
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(statusLabel(status))
                                .foregroundStyle(status?.availability == .valid ? .primary : .secondary)
                            Text(expirationLabel(status))
                                .foregroundStyle(.secondary)
                        }
                        .contextMenu {
                            Button("Retry Certificate", systemImage: "arrow.clockwise") {
                                Task { await gateway.requestRenewal(certificateID: certificate.id) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func statusLabel(_ status: GatewayCertificateStatus?) -> String {
        guard let status else { return "Not issued" }
        if status.availability == .valid { return "Valid" }
        switch status.operation {
        case .queued, .issuing: return "Issuing"
        case .renewing, .replacing: return "Renewing"
        case .waitingRetry: return "Waiting"
        case .suspended: return "Needs attention"
        case .idle: return status.availability == .expired ? "Expired" : "Not issued"
        }
    }

    private func expirationLabel(_ status: GatewayCertificateStatus?) -> String {
        guard let value = status?.notAfter,
              let date = try? Date(value, strategy: .iso8601)
        else { return "—" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

