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
        Section {
            DisclosureGroup("Show Helper Details") {
                LabeledContent("EasyTier Helper") {
                    Text(diagnostics.displayedEasyTierHelper?.easyTierHelperDisplay ?? "Invalid helper metadata")
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
                LabeledContent("Gateway Helper") {
                    Text(diagnostics.displayedGatewayHelper?.componentDisplay ?? "Invalid helper metadata")
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
                LabeledContent("EasyTier Binary") {
                    Text(diagnostics.displayedEasyTierHelper?.binaryDisplay ?? "Invalid helper metadata")
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
                LabeledContent("EasyTier Built") {
                    Text(diagnostics.displayedEasyTierHelper?.buildTime ?? "Invalid helper metadata")
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
                LabeledContent("Gateway Binary") {
                    Text(diagnostics.displayedGatewayHelper?.binaryDisplay ?? "Invalid helper metadata")
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
                LabeledContent("Gateway Built") {
                    Text(diagnostics.displayedGatewayHelper?.buildTime ?? "Invalid helper metadata")
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
            }

            Text(diagnostics.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Helper Diagnostics")
        } footer: {
            Text("Use these details when troubleshooting privileged helper installation or version mismatches.")
        }
        .task(id: refreshID) {
            await diagnostics.refresh(
                easyTierRegistration: store.helperRegistration,
                gatewayRegistration: appContext.runtime.gateway.helperRegistration
            )
        }
    }
}
