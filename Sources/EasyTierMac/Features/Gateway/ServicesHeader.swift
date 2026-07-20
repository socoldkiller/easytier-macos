import SwiftUI

struct ServicesHeader: View {
    var gatewayStatus: String
    var gatewayIsInProgress: Bool
    var serviceSummary: String
    var networkName: String
    var modeLabel: String

    var body: some View {
        HStack(spacing: 10) {
            StatusBadge(
                title: "Network",
                value: networkName,
                systemImage: "globe"
            )
            StatusBadge(
                title: "Gateway",
                value: gatewayStatus,
                systemImage: "network.badge.shield.half.filled",
                width: 150,
                showsProgress: gatewayIsInProgress
            )
            StatusBadge(
                title: "Services",
                value: serviceSummary,
                systemImage: "rectangle.stack",
                width: 160
            )
            StatusBadge(
                title: "Mode",
                value: modeLabel,
                systemImage: "slider.horizontal.3"
            )
            Spacer(minLength: 0)
        }
    }
}
