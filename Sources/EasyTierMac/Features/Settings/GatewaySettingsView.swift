import SwiftUI

struct GatewaySettingsView: View {
    @Environment(AppContext.self) private var appContext

    private var gateway: GatewayRuntimeController { appContext.runtime.gateway }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gateway")
                        .font(.title2.weight(.semibold))
                    Text("TLS for Published Services.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                GatewayTLSSettingsSection(gateway: gateway)
                GatewayAdvancedSettingsSection(gateway: gateway)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .scrollIndicators(.hidden, axes: .vertical)
        .hideScrollViewScrollers()
    }
}
