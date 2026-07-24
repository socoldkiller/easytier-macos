import SwiftUI

struct GatewaySettingsView: View {
    @Environment(AppContext.self) private var appContext

    private var gateway: GatewayRuntimeController { appContext.runtime.gateway }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: SettingsLayoutMetrics.paneSectionSpacing) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gateway")
                        .font(.title2)
                    Text("Published Services, automatic HTTPS, DNS validation, and certificates.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                GeneralGatewaySettingsSection()
                GatewayTLSSettingsSection(gateway: gateway)
                GatewayDNSCredentialsSettingsSection(gateway: gateway)
                GatewayCertificatesSettingsSection(gateway: gateway)
                GatewayAdvancedSettingsSection(gateway: gateway)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, SettingsLayoutMetrics.paneVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .scrollIndicators(.hidden, axes: .vertical)
        .hideScrollViewScrollers()
    }
}
