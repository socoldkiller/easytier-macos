import EasyTierShared
import SwiftUI

struct PublishedServicesGrid: View {
    let rows: [PublishedServiceTableRow]
    @Binding var isScrolling: Bool
    @Binding var globalScrolling: Bool
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

    var body: some View {
        WorkspaceDataGrid(
            rows: rows,
            columns: PublishedServiceGridColumn.allCases,
            minimumRowHeight: 44,
            isScrolling: $isScrolling,
            globalScrolling: $globalScrolling
        ) { row, layout in
            PublishedServiceGridRowView(
                row: row,
                layout: layout,
                gatewayBusy: gatewayBusy,
                workingServiceID: workingServiceID,
                onSetEnabled: onSetEnabled,
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
}
