import SwiftUI

struct GatewaySettingsView: View {
    @Environment(AppContext.self) private var appContext

    private var gateway: GatewayRuntimeController { appContext.runtime.gateway }

    var body: some View {
        SettingsForm {
            GatewayTLSSettingsSection(gateway: gateway)
            GatewayDNSCredentialsSettingsSection(gateway: gateway)
        }
    }
}
