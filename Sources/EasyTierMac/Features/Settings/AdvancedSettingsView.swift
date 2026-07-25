import SwiftUI

struct AdvancedSettingsView: View {
    @Environment(AppContext.self) private var appContext

    @Binding var rpcListenEnabled: Bool
    @Binding var rpcListenPort: Int
    @Binding var rpcPortalWhitelist: [String]
    let commit: () -> Void

    private var appearance: AppAppearanceSettings { appContext.settings.appearance }

    var body: some View {
        SettingsForm {
            RPCServerSettingsSection(
                isEnabled: $rpcListenEnabled,
                port: $rpcListenPort,
                whitelist: $rpcPortalWhitelist,
                commit: commit
            )

            Section {
                SettingsSwitch(
                    "Use Backgrounds Behind Panels",
                    isOn: appearance.glassPanelBackgroundsEnabledBinding
                )
                .disabled(!appearance.glassEffectsEnabled)
            } header: {
                Text("Experimental Appearance")
            } footer: {
                Text("Panel backgrounds require Frosted Glass and may change as the appearance evolves.")
            }

            HelperDiagnosticsSection()
        }
    }
}
