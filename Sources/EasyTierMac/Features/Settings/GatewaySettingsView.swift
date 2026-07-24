import SwiftUI

struct GatewaySettingsView: View {
    @Environment(AppContext.self) private var appContext

    private var gateway: GatewayRuntimeController { appContext.runtime.gateway }

    var body: some View {
        Form {
            GatewayTLSSettingsSection(gateway: gateway)
            GatewayDNSCredentialsSettingsSection(gateway: gateway)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden, axes: .vertical)
        .hideScrollViewScrollers()
    }
}
