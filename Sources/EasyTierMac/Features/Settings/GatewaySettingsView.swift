import SwiftUI

struct GatewaySettingsView: View {
    @Environment(AppContext.self) private var appContext

    private var gateway: GatewayRuntimeController { appContext.runtime.gateway }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gateway")
                        .font(.title2)
                        .bold()
                    Text("Automatic HTTPS for Published Services.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                CardSection(
                    "Automatic HTTPS",
                    systemImage: "lock.shield",
                    footer: "Certificates are issued and renewed automatically when you publish a service."
                ) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Automatic certificate management")
                                .bold()
                            Text("Let's Encrypt and HTTP-01 are used by default.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        StatusPill(
                            gateway.isAutomaticHTTPSReady
                                ? "Configured"
                                : gateway.services.isEmpty ? "Ready When Needed" : "Email Needed",
                            tone: gateway.isAutomaticHTTPSReady
                                ? .positive
                                : gateway.services.isEmpty ? .neutral : .warning
                        )
                    }
                }

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
