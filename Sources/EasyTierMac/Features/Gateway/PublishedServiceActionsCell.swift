import EasyTierShared
import SwiftUI

struct PublishedServiceActionsCell: View {
    var row: PublishedServiceTableRow
    var actionsDisabled: Bool
    var onOpen: (PublishedServiceTableRow) -> Void
    var onCopyDomain: (GatewayPublishedService) -> Void
    var onCopyProxyIPv4: (PublishedServiceTableRow) -> Void
    var onEditService: (GatewayPublishedService) -> Void
    var onConfigureSSL: () -> Void
    var onRetryCertificate: (GatewayPublishedService) -> Void
    var onDelete: (GatewayPublishedService) -> Void

    var body: some View {
        Menu("More options", systemImage: "ellipsis") {
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
        .labelStyle(.iconOnly)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .controlSize(.small)
        .help("More options for \(row.publicHostname)")
        .accessibilityLabel(Text("More options for \(row.publicHostname)"))
    }
}
