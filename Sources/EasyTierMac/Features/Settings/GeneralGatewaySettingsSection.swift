import SwiftUI

struct GeneralGatewaySettingsSection: View {
    @Environment(AppContext.self) private var appContext

    @State private var isChangingGateway = false
    @State private var errorMessage: String?

    private var gateway: GatewayRuntimeController { appContext.runtime.gateway }

    private var presentation: GatewayRuntimePresentation {
        GatewayRuntimePresentation(
            status: gateway.status,
            desiredEnabled: gateway.desiredEnabled,
            services: gateway.services,
            magicDNSState: gateway.magicDNSState
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
                            tone: presentation.tone.statusPillTone,
                            showsProgress: presentation.isInProgress
                        )
                        Toggle("Gateway", isOn: gatewayEnabledBinding)
                            .labelsHidden()
                            .disabled(isChangingGateway || gateway.isBusy)
                    }
                }
            }

            if let displayedError {
                ErrorBanner(message: displayedError)
            }
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
