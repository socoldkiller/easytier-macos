import SwiftUI

struct ServicesHeader: View {
    var gatewayStatus: String
    var gatewayIsInProgress: Bool
    var serviceSummary: String
    var networkName: String
    var modeLabel: String

    var body: some View {
        StatusBadgeGroup {
            StatusBadge(
                title: "Network",
                value: networkName,
                systemImage: "globe"
            )
            StatusBadgeDivider()
            StatusBadge(
                title: "Gateway",
                value: gatewayStatus,
                systemImage: "network.badge.shield.half.filled",
                width: 150,
                showsProgress: gatewayIsInProgress
            )
            StatusBadgeDivider()
            StatusBadge(
                title: "Services",
                value: serviceSummary,
                systemImage: "rectangle.stack",
                width: 160
            )
            StatusBadgeDivider()
            StatusBadge(
                title: "Mode",
                value: modeLabel,
                systemImage: "slider.horizontal.3"
            )
        }
    }
}
