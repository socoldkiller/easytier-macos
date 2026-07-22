import SwiftUI

struct GatewayAdvancedSettingsSection: View {
    let gateway: GatewayRuntimeController

    var body: some View {
        ExpandableSettingsGroup("Advanced") {
            GatewayTLSSettingsSection(gateway: gateway)
            GatewayDNSCredentialsSettingsSection(gateway: gateway)

            CardSection(
                "Listeners",
                systemImage: "point.3.connected.trianglepath.dotted"
            ) {
                SettingsInlineRow("HTTP-01") {
                    ListenerStatusText(
                        address: gateway.status.listeners.http,
                        inactiveDescription: "Not Listening · TCP 80"
                    )
                }
                SettingsRowDivider()
                SettingsInlineRow("Local HTTPS") {
                    ListenerStatusText(
                        address: gateway.status.listeners.https,
                        inactiveDescription: "Not Listening · TCP 443"
                    )
                }
                SettingsRowDivider()
                SettingsInlineRow("Local DNS") {
                    ListenerStatusText(
                        address: gateway.status.listeners.dns,
                        inactiveDescription: "Not Listening · TCP/UDP 53535"
                    )
                }
            }

            Text("TCP 80 ingress must preserve the Host header and the HTTP-01 challenge path.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 2)
        }
    }
}
