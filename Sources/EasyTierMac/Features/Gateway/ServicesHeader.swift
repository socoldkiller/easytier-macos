import SwiftUI

struct ServicesHeader: View {
    var gatewayStatus: String
    var gatewayIsInProgress: Bool
    var serviceCount: Int
    var liveCount: Int
    var networkName: String

    var body: some View {
        HStack(spacing: 10) {
            StatusBadge(
                title: "Gateway",
                value: gatewayStatus,
                systemImage: "network.badge.shield.half.filled",
                width: 142,
                showsProgress: gatewayIsInProgress
            )
            StatusBadge(
                title: "Services",
                value: serviceCount.formatted(),
                systemImage: "rectangle.stack",
                width: 122
            )
            StatusBadge(
                title: "Live",
                value: liveCount.formatted(),
                systemImage: "checkmark.circle.fill",
                width: 112
            )
            StatusBadge(
                title: "Network",
                value: networkName,
                systemImage: "globe"
            )
            Spacer(minLength: 0)
        }
    }
}
