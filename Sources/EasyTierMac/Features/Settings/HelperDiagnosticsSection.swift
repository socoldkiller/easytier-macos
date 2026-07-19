import EasyTierShared
import SwiftUI

struct HelperDiagnosticsSection: View {
    @Environment(AppContext.self) private var appContext

    @State private var diagnostics = HelperDiagnosticsController()

    private var store: EasyTierAppStore { appContext.workspace.store }

    private var refreshID: String {
        "\(String(describing: store.helperRegistration?.state))-\(String(describing: appContext.runtime.gateway.helperRegistration?.state))"
    }

    var body: some View {
        ExpandableSettingsGroup("Helper Diagnostics") {
            SettingsCard {
                SettingsInlineRow("EasyTier Helper") {
                    Text(diagnostics.displayedEasyTierHelper.easyTierHelperDisplay)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
                SettingsRowDivider()
                SettingsInlineRow("Gateway Helper") {
                    Text(diagnostics.displayedGatewayHelper.componentDisplay)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
                SettingsRowDivider()
                SettingsInlineRow("EasyTier Binary") {
                    Text(diagnostics.displayedEasyTierHelper.binaryDisplay)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
                SettingsRowDivider()
                SettingsInlineRow("EasyTier Built") {
                    Text(diagnostics.displayedEasyTierHelper.buildTime)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
                SettingsRowDivider()
                SettingsInlineRow("Gateway Binary") {
                    Text(diagnostics.displayedGatewayHelper.binaryDisplay)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
                SettingsRowDivider()
                SettingsInlineRow("Gateway Built") {
                    Text(diagnostics.displayedGatewayHelper.buildTime)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
            }

            Text(diagnostics.status)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 2)
        }
        .task(id: refreshID) {
            await diagnostics.refresh(
                easyTierRegistration: store.helperRegistration,
                gatewayRegistration: appContext.runtime.gateway.helperRegistration
            )
        }
    }
}
