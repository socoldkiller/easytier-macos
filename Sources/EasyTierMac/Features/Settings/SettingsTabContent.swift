import EasyTierShared
import SwiftUI

struct SettingsTabContent: View {
    @Environment(AppContext.self) private var appContext

    let selection: EasyTierSettingsTab
    @Binding var rpcListenEnabled: Bool
    @Binding var rpcListenPort: Int
    @Binding var rpcPortalWhitelist: [String]
    @Binding var magicDNSSuffix: String
    let commitModeSettings: () -> Void
    let commitMagicDNSSettings: (MagicDNSSettings) -> Void

    var body: some View {
        switch selection {
        case .account:
            AccountSettingsView()
        case .general:
            GeneralSettingsView()
        case .network:
            NetworkSettingsView(
                dnsSuffix: $magicDNSSuffix,
                managedDNSSuffix: appContext.runtime.gateway.defaultDNSZoneBinding?.dnsSuffix,
                commit: commitMagicDNSSettings
            )
            .disabled(!appContext.workspace.store.persistenceIsReady)
        case .advanced:
            AdvancedSettingsView(
                rpcListenEnabled: $rpcListenEnabled,
                rpcListenPort: $rpcListenPort,
                rpcPortalWhitelist: $rpcPortalWhitelist,
                commit: commitModeSettings
            )
            .disabled(!appContext.workspace.store.persistenceIsReady)
        case .about:
            EasyTierAboutView()
        }
    }
}
