import EasyTierShared
import Foundation
import SwiftUI

struct PublishedServicesGrid: View {
    let rows: [PublishedServiceTableRow]
    @Binding var isScrolling: Bool
    @Binding var globalScrolling: Bool
    let gatewayBusy: Bool
    let workingServiceID: String?
    let feedbackOperations: [String: PublishedServiceFeedbackOperation]
    let onSetEnabled: (Bool, GatewayPublishedService) -> Void
    let onOpen: (PublishedServiceTableRow) -> Void
    let onCopyDomain: (GatewayPublishedService) -> Void
    let onCopyProxyIPv4: (PublishedServiceTableRow) -> Void
    let onEditService: (GatewayPublishedService) -> Void
    let onRetryCertificate: (GatewayPublishedService) -> Void
    let onDelete: (GatewayPublishedService) -> Void
    let onConsumeFeedbackOperation: (String, UUID) -> Void

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
                feedbackOperation: feedbackOperations[row.id],
                onSetEnabled: onSetEnabled,
                onOpen: onOpen,
                onCopyDomain: onCopyDomain,
                onCopyProxyIPv4: onCopyProxyIPv4,
                onEditService: onEditService,
                onRetryCertificate: onRetryCertificate,
                onDelete: onDelete,
                onConsumeFeedbackOperation: onConsumeFeedbackOperation
            )
        }
    }
}
