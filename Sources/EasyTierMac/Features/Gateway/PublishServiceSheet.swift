import AppKit
import EasyTierShared
import SwiftUI

struct PublishServiceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(AppContext.self) private var appContext

    let preferredTargetPeerID: String?

    @State private var serviceLabel = ""
    @State private var targetPort = "3000"
    @State private var selectedTargetPeerID: String
    @State private var certificateMode = PublishedServiceCertificateMode.automatic
    @State private var certificateAuthority = GatewayCertificateAuthority.letsEncrypt
    @State private var challengeMode = PublishedServiceChallengeMode.http01
    @State private var dnsCredentialID: String?
    @State private var showsHTTPSOptions = false
    @State private var hasEditedPublicName = false
    @State private var hasEditedPort = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case publicName
        case targetPort
    }

    private var store: EasyTierAppStore { appContext.workspace.store }
    private var gateway: GatewayRuntimeController { appContext.runtime.gateway }

    private var targetOptions: [PublishedServiceTargetOption] {
        PublishedServiceTargetOption.creationOptions(members: gateway.topologyMembers)
    }

    private var targetOptionIDs: [String] {
        targetOptions.map(\.peerID)
    }

    private var selectedTarget: PublishedServiceTargetOption? {
        targetOptions.first { $0.peerID == selectedTargetPeerID }
    }

    private var trimmedDNSSuffix: String {
        let suffix = gateway.appliedMagicDNSSuffix ?? store.magicDNSSettings.dnsSuffix
        return suffix.hasSuffix(".") ? String(suffix.dropLast()) : suffix
    }

    private var targetDomain: String {
        guard let selectedTarget else { return "member" }
        return MagicDNSDisplay.memberDomain(
            hostname: selectedTarget.hostname,
            config: store.selectedConfig,
            settings: store.magicDNSSettings
        ) ?? "\(selectedTarget.hostname).\(trimmedDNSSuffix)"
    }

    private var existingPublicHostnames: Set<String> {
        Set(gateway.services.map(\.publicHostname))
    }

    private var normalizedPublicName: String? {
        PublishedServiceFormValidation.normalizedPublicName(serviceLabel)
    }

    private var publicNameError: String? {
        PublishedServiceFormValidation.publicNameError(
            serviceLabel,
            targetDomain: targetDomain,
            existingPublicHostnames: existingPublicHostnames
        )
    }

    private var parsedPort: Int? {
        PublishedServiceFormValidation.parsedPort(targetPort)
    }

    private var portError: String? {
        PublishedServiceFormValidation.portError(targetPort)
    }

    private var savedContactEmail: String? {
        try? GatewayPublishedServicesValidator.normalizeContactEmail(
            gateway.acmeConfiguration?.contactEmail
        )
    }

    private var publicAddressIsValid: Bool {
        normalizedPublicName != nil && publicNameError == nil && selectedTarget != nil
    }

    private var certificateSelection: GatewayServiceCertificateSelection? {
        if certificateMode == .automatic {
            return gateway.defaultDNSCredentialID == nil ? nil : .automatic
        }
        guard let challenge = challengeMode.challenge(credentialID: dnsCredentialID) else {
            return nil
        }
        return .custom(authority: certificateAuthority, challenge: challenge)
    }

    private var canPublish: Bool {
        !isWorking
            && !gateway.isBusy
            && publicAddressIsValid
            && parsedPort != nil
            && savedContactEmail != nil
            && certificateSelection != nil
            && store.selectedConfig != nil
            && gateway.magicDNSState == .ready
    }

    init(preferredTargetPeerID: String? = nil) {
        self.preferredTargetPeerID = preferredTargetPeerID
        _selectedTargetPeerID = State(initialValue: preferredTargetPeerID ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                PublishedServiceSheetHeader(
                    title: "Publish HTTP Service"
                )

                VStack(alignment: .leading, spacing: 14) {
                    PublishedServiceFormRow("Public URL", systemImage: "globe") {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                Text("https://")
                                    .foregroundStyle(.secondary)

                                TextField("service", text: $serviceLabel)
                                    .labelsHidden()
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 104)
                                    .focused($focusedField, equals: .publicName)
                                    .disabled(isWorking)
                                    .onSubmit(focusPort)

                                Text(".\(targetDomain)")
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                Button("Copy URL", systemImage: "doc.on.doc", action: copyPublicURL)
                                    .labelStyle(.iconOnly)
                                    .buttonStyle(.borderless)
                                    .disabled(!publicAddressIsValid)
                                    .help("Copy public URL")
                            }

                            if hasEditedPublicName, let publicNameError {
                                PublishedServiceFieldMessage(
                                    message: publicNameError,
                                    showsError: true
                                )
                            }
                        }
                    }

                    PublishedServiceFormRow("Destination", systemImage: "arrow.right") {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                if targetOptions.isEmpty {
                                    Text("No online members available")
                                        .foregroundStyle(.secondary)
                                } else {
                                    Picker("Target Member", selection: $selectedTargetPeerID) {
                                        ForEach(targetOptions) { target in
                                            Text(target.label)
                                                .tag(target.peerID)
                                        }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                    .frame(width: 204)
                                    .disabled(isWorking)
                                }

                                Text(":")
                                    .foregroundStyle(.tertiary)

                                TextField("Port", text: $targetPort)
                                    .labelsHidden()
                                    .textFieldStyle(.roundedBorder)
                                    .font(.body.monospacedDigit())
                                    .frame(width: 72)
                                    .focused($focusedField, equals: .targetPort)
                                    .disabled(isWorking)
                                    .onSubmit(submitPort)
                            }

                            if hasEditedPort, let portError {
                                PublishedServiceFieldMessage(
                                    message: portError,
                                    showsError: true
                                )
                            }
                        }
                    }

                    if savedContactEmail == nil {
                        PublishedServiceFormRow("Certificate Account", systemImage: "envelope") {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Add a global contact email before requesting certificates.")
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Button(
                                    "Open Gateway Settings",
                                    systemImage: "gear",
                                    action: openGatewaySettings
                                )
                            }
                        }
                    }

                    PublishedServiceHTTPSOptions(
                        isExpanded: $showsHTTPSOptions,
                        certificateMode: $certificateMode,
                        certificateAuthority: $certificateAuthority,
                        challengeMode: $challengeMode,
                        dnsCredentialID: $dnsCredentialID,
                        dnsCredentials: gateway.dnsCredentials,
                        automaticDomain: "*.\(targetDomain)",
                        defaultDNSCredentialID: gateway.defaultDNSCredentialID,
                        status: PublishedServiceSSLProvider(
                            acmeConfiguration: gateway.acmeConfiguration
                        ),
                        isDisabled: isWorking,
                        onManageDNSCredentials: openGatewaySettings
                    )
                }

                if let errorMessage {
                    ErrorBanner(message: errorMessage)
                }
            }
            .padding(20)

            Divider()

            HStack {
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel, action: dismiss.callAsFunction)
                    .disabled(isWorking)
                    .keyboardShortcut(.cancelAction)
                Button(action: publish) {
                    HStack {
                        if isWorking {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(isWorking ? "Publishing…" : "Publish")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canPublish)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .frame(width: 500)
        .controlSize(.regular)
        .task(prepare)
        .onChange(of: targetOptionIDs) { _, _ in
            reconcileTargetSelection()
        }
        .onChange(of: serviceLabel) { oldValue, newValue in
            if oldValue != newValue {
                hasEditedPublicName = true
            }
        }
        .onChange(of: targetPort) { oldValue, newValue in
            if oldValue != newValue {
                hasEditedPort = true
            }
        }
        .onChange(of: focusedField) { oldValue, newValue in
            if oldValue == .publicName, newValue != .publicName {
                normalizePublicName()
            }
        }
    }

    private func prepare() async {
        reconcileTargetSelection()
        focusedField = .publicName
    }

    private func reconcileTargetSelection() {
        selectedTargetPeerID = PublishedServiceTargetOption.initialPeerID(
            in: targetOptions,
            preferredPeerID: selectedTargetPeerID.nilIfEmpty ?? preferredTargetPeerID
        ) ?? ""
    }

    private func focusPort() {
        normalizePublicName()
        focusedField = .targetPort
    }

    private func submitPort() {
        publish()
    }

    private func normalizePublicName() {
        if let normalizedPublicName {
            serviceLabel = normalizedPublicName
        }
    }

    private func publish() {
        guard canPublish,
              let config = store.selectedConfig,
              let port = parsedPort,
              let selectedTarget,
              let certificateSelection
        else {
            hasEditedPublicName = true
            hasEditedPort = true
            return
        }

        normalizePublicName()
        Task {
            isWorking = true
            errorMessage = nil
            defer { isWorking = false }
            do {
                _ = try await gateway.createService(
                    networkConfigID: config.instance_id,
                    targetPeerID: selectedTarget.peerID,
                    targetInstanceID: selectedTarget.instanceID,
                    targetHostname: selectedTarget.hostname,
                    magicDNSSuffix: gateway.appliedMagicDNSSuffix
                        ?? store.magicDNSSettings.dnsSuffix,
                    serviceLabel: serviceLabel,
                    targetPort: port,
                    contactEmail: nil,
                    certificateSelection: certificateSelection
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func openGatewaySettings() {
        appContext.settings.request(.gateway)
        openWindow(id: EasyTierWindowID.settings)
    }

    private func copyPublicURL() {
        guard publicAddressIsValid else { return }
        let publicHostname = PublishedServiceFormValidation.publicHostname(
            publicName: serviceLabel,
            targetDomain: targetDomain
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("https://\(publicHostname)", forType: .string)
    }
}
