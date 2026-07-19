import SwiftUI

struct GeneralGatewaySettingsSection: View {
    @Environment(AppContext.self) private var appContext

    @State private var isChangingGateway = false
    @State private var isShowingPublishedServices = false
    @State private var errorMessage: String?

    private var gateway: GatewayRuntimeController { appContext.runtime.gateway }

    private var presentation: GatewayRuntimePresentation {
        GatewayRuntimePresentation(
            status: gateway.status,
            desiredEnabled: gateway.desiredEnabled,
            services: gateway.services
        )
    }

    private var displayedError: String? {
        if let errorMessage { return errorMessage }
        guard gateway.status.state == .failed else { return nil }
        return gateway.lastError ?? gateway.status.lastError
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardSection("Gateway", systemImage: "network.badge.shield.half.filled") {
                SettingsInlineRow("Gateway") {
                    HStack(spacing: 10) {
                        StatusPill(
                            presentation.statusLabel,
                            tone: presentation.tone.statusPillTone
                        )
                        Toggle("Gateway", isOn: gatewayEnabledBinding)
                            .labelsHidden()
                            .disabled(isChangingGateway || gateway.isBusy)
                    }
                }
                SettingsRowDivider()
                SettingsInlineRow("Published Services") {
                    HStack(spacing: 10) {
                        Text(presentation.serviceCountLabel)
                            .foregroundStyle(.secondary)
                        Button(
                            "Manage…",
                            systemImage: "rectangle.stack",
                            action: showPublishedServices
                        )
                        .controlSize(.small)
                    }
                }
            }

            if let displayedError {
                ErrorBanner(message: displayedError)
            }
        }
        .sheet(isPresented: $isShowingPublishedServices) {
            PublishedServicesSheet()
        }
    }

    private var gatewayEnabledBinding: Binding<Bool> {
        Binding(
            get: { gateway.desiredEnabled },
            set: { enabled in
                setGatewayEnabled(enabled)
            }
        )
    }

    private func showPublishedServices() {
        isShowingPublishedServices = true
    }

    private func setGatewayEnabled(_ enabled: Bool) {
        Task {
            isChangingGateway = true
            errorMessage = nil
            defer { isChangingGateway = false }
            do {
                try await gateway.setGatewayEnabled(enabled)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
