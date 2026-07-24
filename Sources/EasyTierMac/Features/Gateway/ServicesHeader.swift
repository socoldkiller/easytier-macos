import SwiftUI

struct ServicesHeader: View {
    @Binding var gatewayEnabled: Bool
    var gatewayStatus: String
    var gatewayIsInProgress: Bool
    var gatewayControlDisabled: Bool
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
            StatusBadgeDivider()
            Toggle("Run", isOn: $gatewayEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(gatewayControlDisabled)
                .frame(width: 90)
                .help(gatewayEnabled ? "Pause all published services" : "Run published services")
                .accessibilityLabel("Run Published Services")
        }
    }
}
