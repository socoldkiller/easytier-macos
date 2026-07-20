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
            WorkspaceDataGridCell(.service, layout: layout) {
                PublishedServiceDomainCell(
                    row: row,
                    isWorking: isWorking,
                    onOpen: onOpen
                )
            }

            WorkspaceDataGridCell(.ipv4, layout: layout) {
                PublishedServiceIPv4Cell(row: row)
            }

            WorkspaceDataGridCell(.target, layout: layout) {
                PublishedServiceTargetCell(row: row)
            }

            WorkspaceDataGridCell(.ssl, layout: layout) {
                PublishedServiceSSLCell(provider: row.sslProvider)
            }

            WorkspaceDataGridCell(.expires, layout: layout) {
                PublishedServiceExpiresCell(
                    presentation: row.certificatePresentation
                )
            }

            WorkspaceDataGridCell(.lastOnline, layout: layout) {
                PublishedServiceLastOnlineCell(lastOnlineAt: row.lastOnlineAt)
            }

            WorkspaceDataGridCell(.enabled, layout: layout, alignment: .center) {
                PublishedServiceEnabledCell(
                    row: row,
                    actionsDisabled: actionsDisabled,
                    onSetEnabled: onSetEnabled
                )
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

    private var accessibilitySummary: String {
        [
            "Domain: \(row.publicHostname)",
            "Target: \(row.targetDomain)",
            "Proxy IPv4: \(row.proxyIPv4)",
            "Port: \(row.targetPort)",
            "Protocol: \(row.protocolLabel)",
            "SSL: \(row.sslProvider.label)",
            "Certificate expiration: \(row.certificatePresentation.label)",
            "Status: \(row.presentation.statusLabel), \(row.presentation.detailLabel)",
            row.service.desiredEnabled ? "Enabled" : "Disabled",
            "Last online: \(lastOnlineAccessibilityLabel)",
        ].joined(separator: ", ")
    }

    private var lastOnlineAccessibilityLabel: String {
        row.lastOnlineAt?.formatted(date: .abbreviated, time: .shortened) ?? "Not recorded"
    }
}
