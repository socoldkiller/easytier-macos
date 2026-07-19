import AppKit
import EasyTierShared
import SwiftUI

struct PublishedServicesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(AppContext.self) private var appContext

    @State private var workingServiceID: String?
    @State private var editingService: GatewayPublishedService?
    @State private var deletionCandidate: GatewayPublishedService?
    @State private var errorMessage: String?

    private var store: EasyTierAppStore { appContext.workspace.store }
    private var gateway: GatewayRuntimeController { appContext.runtime.gateway }

    private var runtimePresentation: GatewayRuntimePresentation {
        GatewayRuntimePresentation(
            status: gateway.status,
            desiredEnabled: gateway.desiredEnabled,
            services: gateway.services
        )
    }

    private var displayedError: String? {
        errorMessage ?? gateway.lastError
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Published Services")
                    .font(.title3)
                    .bold()
                Spacer(minLength: 12)
                StatusPill(
                    runtimePresentation.statusLabel,
                    tone: runtimePresentation.tone.statusPillTone
                )
            }

            if !gateway.isTLSConfigured {
                GatewayTLSRequirementBanner(action: openGatewaySettings)
            }

            if let displayedError {
                ErrorBanner(message: displayedError)
            }

            if gateway.services.isEmpty {
                ContentUnavailableView(
                    "No Published Services",
                    systemImage: "rectangle.stack.badge.plus",
                    description: Text("Right-click an online member in Status and choose Publish Service…")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PublishedServicesList(
                    services: gateway.services,
                    status: gateway.status,
                    gatewayEnabled: gateway.desiredEnabled,
                    tlsConfigured: gateway.isTLSConfigured,
                    gatewayBusy: gateway.isBusy,
                    workingServiceID: workingServiceID,
                    onSetEnabled: setEnabled,
                    onEditPort: editPort,
                    onRetryCertificate: retryCertificate,
                    onOpen: open,
                    onCopyHostname: copyHostname,
                    onDelete: requestDeletion
                )
            }

            HStack {
                Spacer(minLength: 0)
                Button("Done", action: dismiss.callAsFunction)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 720, height: 560)
        .task(prepare)
        .sheet(item: $editingService) { service in
            EditPublishedServiceSheet(service: service) { port in
                updatePort(port, service: service)
            }
        }
        .alert(
            "Delete Published Service?",
            isPresented: deletionAlertBinding,
            presenting: deletionCandidate
        ) { service in
            Button("Delete \(service.publicHostname)", role: .destructive) {
                delete(service)
            }
            Button("Cancel", role: .cancel) {
                deletionCandidate = nil
            }
        } message: { service in
            Text("The public hostname and its certificate configuration will be removed.")
        }
    }

    private var deletionAlertBinding: Binding<Bool> {
        Binding(
            get: { deletionCandidate != nil },
            set: { isPresented in
                if !isPresented { deletionCandidate = nil }
            }
        )
    }

    private func prepare() async {
        await GatewayTopologyBridge.reconcile(gateway: gateway, store: store)
        await gateway.refreshStatus()
    }

    private func setEnabled(_ enabled: Bool, service: GatewayPublishedService) {
        perform(service) {
            if enabled {
                await GatewayTopologyBridge.reconcile(gateway: gateway, store: store)
            }
            try await gateway.setServiceEnabled(enabled, serviceID: service.id)
        }
    }

    private func editPort(_ service: GatewayPublishedService) {
        editingService = service
    }

    private func updatePort(_ port: Int, service: GatewayPublishedService) {
        perform(service) {
            try await gateway.updatePort(serviceID: service.id, port: port)
        }
    }

    private func retryCertificate(_ service: GatewayPublishedService) {
        Task {
            workingServiceID = service.id
            errorMessage = nil
            await gateway.requestRenewal(certificateID: service.id)
            workingServiceID = nil
        }
    }

    private func open(_ service: GatewayPublishedService) {
        guard let url = URL(string: "https://\(service.publicHostname)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func copyHostname(_ service: GatewayPublishedService) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(service.publicHostname, forType: .string)
    }

    private func requestDeletion(_ service: GatewayPublishedService) {
        deletionCandidate = service
    }

    private func delete(_ service: GatewayPublishedService) {
        deletionCandidate = nil
        perform(service) {
            try await gateway.deleteService(service.id)
        }
    }

    private func openGatewaySettings() {
        appContext.settings.request(.gateway)
        dismiss()
        openWindow(id: EasyTierWindowID.settings)
    }

    private func perform(
        _ service: GatewayPublishedService,
        operation: @escaping @MainActor () async throws -> Void
    ) {
        Task {
            workingServiceID = service.id
            errorMessage = nil
            defer { workingServiceID = nil }
            do {
                try await operation()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
