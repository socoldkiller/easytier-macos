import AppKit
import EasyTierShared
import SwiftUI

struct ServicesView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow
    @Environment(\.windowPresentationActivity) private var presentationActivity
    @Environment(AppContext.self) private var appContext

    @State private var searchText = ""
    @State private var serviceGridIsScrolling = false
    @State private var workingServiceID: String?
    @State private var editingService: GatewayPublishedService?
    @State private var deletionCandidate: GatewayPublishedService?
    @State private var errorMessage: String?

    var onPublishService: () -> Void = {}

    private var store: EasyTierAppStore { appContext.workspace.store }
    private var gateway: GatewayRuntimeController { appContext.runtime.gateway }

    private var serviceCreationTargets: [PublishedServiceTargetOption] {
        PublishedServiceTargetOption.creationOptions(members: gateway.topologyMembers)
    }

    private var canBeginPublishingService: Bool {
        gateway.magicDNSState == .ready && !serviceCreationTargets.isEmpty
    }

    private var publishingEmptyStateDescription: String {
        if gateway.magicDNSState != .ready {
            return "Wait for Magic DNS to become ready before publishing a service."
        }
        if serviceCreationTargets.isEmpty {
            return "Run a network with at least one online member before publishing a service."
        }
        return "Publish an HTTP service from an online network member."
    }

    private var displayedError: String? {
        errorMessage ?? gateway.convergence.message ?? gateway.lastError
            ?? gateway.status.runtimeIssues.last?.message
    }

    private var display: PublishedServicesDisplayModel {
        PublishedServicesDisplayModel(
            services: gateway.services,
            status: gateway.status,
            gatewayEnabled: gateway.desiredEnabled,
            acmeConfiguration: gateway.acmeConfiguration,
            networkName: gateway.publishingNetworkName,
            members: gateway.topologyMembers,
            searchText: searchText,
            magicDNSState: gateway.magicDNSState,
            magicDNSStateByServiceID: gateway.magicDNSStateByServiceID,
            convergence: gateway.convergence
        )
    }

    var body: some View {
        @Bindable var store = self.store

        VStack(alignment: .leading, spacing: 14) {
            header

            if !display.rows.isEmpty || display.searchIsActive {
                WorkspaceSearchField(
                    text: $searchText,
                    prompt: "Search services",
                    resultCount: display.filteredRows.count,
                    totalCount: display.rows.count
                )
            }

            if !gateway.isTLSConfigured {
                GatewayTLSRequirementBanner(action: openGatewaySettings)
                    .transition(reduceMotion ? .opacity : .easyTierSlideFade(edge: .top, distance: 8))
            }

            if let displayedError {
                ErrorBanner(message: displayedError)
                    .transition(reduceMotion ? .opacity : .easyTierSlideFade(edge: .top, distance: 8))
            }

            if !display.certificateFailures.isEmpty {
                GatewayCertificateErrorBanner(failures: display.certificateFailures)
                    .transition(reduceMotion ? .opacity : .easyTierSlideFade(edge: .top, distance: 8))
            }

            MotionSwitch(id: display.contentMotionID, insertionEdge: .bottom) {
                servicesContent(display)
            }
        }
        .padding()
        .animation(
            presentationActivity.allowsAnimations
                ? EasyTierMotion.content(reduceMotion: reduceMotion)
                : nil,
            value: displayedError
        )
        .animation(
            presentationActivity.allowsAnimations
                ? EasyTierMotion.content(reduceMotion: reduceMotion)
                : nil,
            value: display.certificateFailures
        )
        .task(prepare)
        .sheet(item: $editingService) { service in
            let row = display.rows.first { $0.id == service.id }
            EditPublishedServiceSheet(
                service: service,
                targetOptions: PublishedServiceTargetOption.options(
                    for: service,
                    currentIPv4: row?.proxyIPv4 ?? "—",
                    members: gateway.topologyMembers
                ),
                dnsCredentials: gateway.dnsCredentials,
                sslProvider: row?.sslProvider
                    ?? PublishedServiceSSLProvider(acmeConfiguration: gateway.acmeConfiguration),
                onConfigureSSL: openGatewaySettings
            ) { target, port, certificatePolicy in
                updateService(
                    target: target,
                    port: port,
                    certificatePolicy: certificatePolicy,
                    service: service
                )
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
        } message: { _ in
            Text("The public domain and its certificate configuration will be removed.")
        }
    }

    private var header: some View {
        ServicesHeader(
            gatewayStatus: display.runtimePresentation.statusLabel,
            gatewayIsInProgress: display.runtimePresentation.isInProgress,
            serviceSummary: display.serviceSummary,
            networkName: display.networkName,
            modeLabel: store.mode.label
        )
    }

    @ViewBuilder
    private func servicesContent(_ display: PublishedServicesDisplayModel) -> some View {
        @Bindable var store = self.store
        if display.rows.isEmpty {
            ContentUnavailableView {
                Label(
                    "No Published Services",
                    systemImage: "rectangle.stack.badge.plus"
                )
            } description: {
                Text(publishingEmptyStateDescription)
            } actions: {
                Button("Publish Service…", systemImage: "plus", action: onPublishService)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canBeginPublishingService)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if display.searchIsActive, display.filteredRows.isEmpty {
            ContentUnavailableView(
                "No Search Results",
                systemImage: "magnifyingglass",
                description: Text(
                    "Try a domain, target, address, protocol, SSL provider, or status."
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            PublishedServicesGrid(
                rows: display.filteredRows,
                isScrolling: $serviceGridIsScrolling,
                globalScrolling: $store.isAnyViewScrolling,
                gatewayBusy: gateway.isBusy,
                workingServiceID: workingServiceID,
                onSetEnabled: setEnabled,
                onOpen: open,
                onCopyDomain: copyDomain,
                onCopyProxyIPv4: copyProxyIPv4,
                onEditService: editService,
                onConfigureSSL: openGatewaySettings,
                onRetryCertificate: retryCertificate,
                onDelete: requestDeletion
            )
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
        await gateway.refreshStatus()
    }

    private func setEnabled(_ enabled: Bool, service: GatewayPublishedService) {
        perform(service) {
            if enabled {
                guard gateway.magicDNSState != .disabled else {
                    throw GatewayConfigurationValidationError.invalid(
                        "Turn on Magic DNS before enabling this service."
                    )
                }
            }
            try await gateway.setServiceEnabled(enabled, serviceID: service.id)
        }
    }

    private func editService(_ service: GatewayPublishedService) {
        editingService = service
    }

    private func updateService(
        target: PublishedServiceTargetOption,
        port: Int,
        certificatePolicy: GatewayCertificatePolicy,
        service: GatewayPublishedService
    ) {
        perform(service) {
            try await gateway.updateService(
                serviceID: service.id,
                targetPeerID: target.peerID,
                targetInstanceID: target.instanceID,
                targetHostname: target.hostname,
                magicDNSSuffix: gateway.appliedMagicDNSSuffix
                    ?? store.magicDNSSettings.dnsSuffix,
                port: port,
                certificatePolicy: certificatePolicy
            )
        }
    }

    private func retryCertificate(_ service: GatewayPublishedService) {
        Task {
            workingServiceID = service.id
            errorMessage = nil
            await gateway.requestRenewal(certificateID: service.id)
            errorMessage = gateway.lastError
            workingServiceID = nil
        }
    }

    private func open(_ row: PublishedServiceTableRow) {
        guard let url = row.publicURL else { return }
        NSWorkspace.shared.open(url)
    }

    private func copyDomain(_ service: GatewayPublishedService) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(service.publicHostname, forType: .string)
    }

    private func copyProxyIPv4(_ row: PublishedServiceTableRow) {
        guard row.proxyIPv4 != "—" else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(row.proxyIPv4, forType: .string)
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
