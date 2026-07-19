import EasyTierShared
import SwiftUI

struct PublishedServiceGridRowView: View {
    let row: PublishedServiceTableRow
    let layout: WorkspaceDataGridLayout<PublishedServiceGridColumn>
    let gatewayBusy: Bool
    let workingServiceID: String?
    let onSetEnabled: (Bool, GatewayPublishedService) -> Void
    let onOpen: (PublishedServiceTableRow) -> Void
    let onCopyDomain: (GatewayPublishedService) -> Void
    let onCopyProxyIPv4: (PublishedServiceTableRow) -> Void
    let onEditService: (GatewayPublishedService) -> Void
    let onConfigureSSL: () -> Void
    let onRetryCertificate: (GatewayPublishedService) -> Void
    let onDelete: (GatewayPublishedService) -> Void

    private var isWorking: Bool {
        workingServiceID == row.id
    }

    private var actionsDisabled: Bool {
        gatewayBusy || isWorking
    }

    var body: some View {
        HStack(spacing: 0) {
            WorkspaceDataGridCell(.domain, layout: layout) {
                PublishedServiceDomainCell(
                    row: row,
                    onOpen: onOpen
                )
            }

            WorkspaceDataGridCell(.proxyIPv4, layout: layout) {
                Text(row.proxyIPv4)
                    .font(.callout.monospaced())
                    .foregroundStyle(row.proxyIPv4 == "—" ? Color.secondary : Color.primary)
                    .lineLimit(1)
                    .textSelection(.enabled)
                    .help(proxyIPv4Help)
            }

            WorkspaceDataGridCell(.port, layout: layout) {
                Text(row.targetPort, format: .number.grouping(.never))
                    .monospacedDigit()
            }

            WorkspaceDataGridCell(.protocol, layout: layout) {
                Text(row.protocolLabel)
                    .font(.callout.monospaced())
                    .help("HTTP upstream; public access uses HTTPS when SSL is active.")
            }

            WorkspaceDataGridCell(.ssl, layout: layout) {
                PublishedServiceSSLCell(provider: row.sslProvider)
            }

            WorkspaceDataGridCell(.status, layout: layout) {
                PublishedServiceStatusCell(
                    row: row,
                    isWorking: isWorking,
                    actionsDisabled: actionsDisabled,
                    onSetEnabled: onSetEnabled
                )
            }

            WorkspaceDataGridCell(.lastOnline, layout: layout) {
                PublishedServiceLastOnlineCell(lastOnlineAt: row.lastOnlineAt)
            }

            WorkspaceDataGridCell(.more, layout: layout, alignment: .center) {
                PublishedServiceActionsCell(
                    row: row,
                    actionsDisabled: actionsDisabled,
                    onOpen: onOpen,
                    onCopyDomain: onCopyDomain,
                    onCopyProxyIPv4: onCopyProxyIPv4,
                    onEditService: onEditService,
                    onConfigureSSL: onConfigureSSL,
                    onRetryCertificate: onRetryCertificate,
                    onDelete: onDelete
                )
            }
        }
        .contentShape(.rect)
        .contextMenu {
            PublishedServiceMenuCommands(
                row: row,
                actionsDisabled: actionsDisabled,
                onOpen: onOpen,
                onCopyDomain: onCopyDomain,
                onCopyProxyIPv4: onCopyProxyIPv4,
                onEditService: onEditService,
                onConfigureSSL: onConfigureSSL,
                onRetryCertificate: onRetryCertificate,
                onDelete: onDelete
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(accessibilitySummary))
    }

    private var proxyIPv4Help: String {
        if row.proxyIPv4 == "—" {
            return "The target IPv4 is unavailable until the publishing network reports its topology."
        }
        return "Proxy target IPv4"
    }

    private var accessibilitySummary: String {
        [
            "Domain: \(row.publicHostname)",
            "Target: \(row.targetDomain)",
            "Proxy IPv4: \(row.proxyIPv4)",
            "Port: \(row.targetPort)",
            "Protocol: \(row.protocolLabel)",
            "SSL: \(row.sslProvider.label)",
            "Status: \(row.presentation.statusLabel), \(row.presentation.detailLabel)",
            row.service.desiredEnabled ? "Enabled" : "Disabled",
            "Last online: \(lastOnlineAccessibilityLabel)",
        ].joined(separator: ", ")
    }

    private var lastOnlineAccessibilityLabel: String {
        row.lastOnlineAt?.formatted(date: .abbreviated, time: .shortened) ?? "Not recorded"
    }
}
