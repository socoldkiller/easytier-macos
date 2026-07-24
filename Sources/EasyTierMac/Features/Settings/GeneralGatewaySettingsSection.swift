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
            magicDNSState: gateway.magicDNSState,
            convergence: gateway.convergence
        )
    }

    private var displayedError: String? {
        if let errorMessage { return errorMessage }
        return gateway.convergence.message
            ?? gateway.lastError
            ?? gateway.status.runtimeIssues.last?.message
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardSection(
                "Published Services",
                systemImage: "network.badge.shield.half.filled",
                footer: "Publishing a service turns this on automatically. Turn it off to pause all published services."
            ) {
                SettingsInlineRow("Run Published Services") {
                    HStack(spacing: 10) {
                        StatusPill(
                            presentation.statusLabel,
                            tone: presentation.tone.statusPillTone,
                            showsProgress: presentation.isInProgress
                        )
                        Toggle("Run Published Services", isOn: gatewayEnabledBinding)
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
