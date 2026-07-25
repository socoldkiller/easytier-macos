import EasyTierShared
import SwiftUI

struct NetworkSettingsView: View {
    @Environment(AppContext.self) private var appContext

    @Binding var dnsSuffix: String
    let managedDNSSuffix: String?
    let commit: (MagicDNSSettings) -> Void

    private var gateway: GatewayRuntimeController { appContext.runtime.gateway }

    var body: some View {
        SettingsForm {
            MagicDNSSettingsSection(
                dnsSuffix: $dnsSuffix,
                managedDNSSuffix: managedDNSSuffix,
                commit: commit
            )

            Section {
                GatewayTLSSettingsSection(gateway: gateway)
                GatewayDNSCredentialsSettingsSection(gateway: gateway)
            } header: {
                HStack(spacing: 6) {
                    Text("Gateway")
                    BetaBadge()
                }
            }
        }
    }
}
