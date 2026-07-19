import EasyTierShared
import SwiftUI

struct PublishedServiceMenuCommands: View {
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
        Button("Open in Browser", systemImage: "safari") {
            onOpen(row)
        }

        Divider()

        Button("Copy Domain", systemImage: "doc.on.doc") {
            onCopyDomain(row.service)
        }
        Button("Copy Proxy IPv4", systemImage: "doc.on.doc") {
            onCopyProxyIPv4(row)
        }
        .disabled(row.proxyIPv4 == "—")

        Divider()

        Button("Edit Service…", systemImage: "slider.horizontal.3") {
            onEditService(row.service)
        }
        .disabled(actionsDisabled)
        Button("SSL Settings…", systemImage: "lock.shield") {
            onConfigureSSL()
        }
        Button(
            row.presentation.certificateActionTitle,
            systemImage: "arrow.clockwise"
        ) {
            onRetryCertificate(row.service)
        }
        .disabled(actionsDisabled || !row.presentation.canRetryCertificate)

        Divider()

        Button("Delete", systemImage: "trash", role: .destructive) {
            onDelete(row.service)
        }
        .disabled(actionsDisabled)
    }
}
