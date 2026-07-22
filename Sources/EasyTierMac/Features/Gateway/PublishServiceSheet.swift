import AppKit
import EasyTierShared
import SwiftUI

struct PublishServiceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(AppContext.self) private var appContext
    @FocusState private var focusedField: Field?

    let preferredTargetPeerID: String?

    @State private var serviceLabel = ""
    @State private var targetPort = "3000"
    @State private var selectedTargetPeerID: String
    @State private var certificateAuthority = GatewayCertificateAuthority.letsEncrypt
    @State private var challengeMode = PublishedServiceChallengeMode.http01
    @State private var dnsCredentialID: String?
    @State private var contactEmail = ""
    @State private var showsHTTPSOptions = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    private enum Field: Hashable {
        case serviceLabel
        case targetPort
        case contactEmail
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

    private var targetDomain: String {
        guard let selectedTarget else { return "member" }
        return MagicDNSDisplay.memberDomain(
            hostname: selectedTarget.hostname,
            config: store.selectedConfig,
            settings: store.magicDNSSettings
        ) ?? "\(selectedTarget.hostname).\(trimmedDNSSuffix)"
    }

    private var publicHostname: String {
        let label = serviceLabel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(label.isEmpty ? "service" : label).\(targetDomain)"
    }

    private var publicURL: String {
        "https://\(publicHostname)"
    }

    private var targetSummary: String {
        let port = targetPort.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(targetDomain):\(port.isEmpty ? "—" : port)"
    }

    private var trimmedDNSSuffix: String {
        let suffix = gateway.appliedMagicDNSSuffix ?? store.magicDNSSettings.dnsSuffix
        return suffix.hasSuffix(".") ? String(suffix.dropLast()) : suffix
    }

    private var savedContactEmail: String? {
        try? GatewayPublishedServicesValidator.normalizeContactEmail(
            gateway.acmeConfiguration?.contactEmail
        )
    }

    private var normalizedContactEmail: String? {
        try? GatewayPublishedServicesValidator.normalizeContactEmail(contactEmail)
    }

    private var requiresContactEmail: Bool {
        savedContactEmail == nil
    }

    private var contactEmailIsInvalid: Bool {
        !contactEmail.isEmpty && normalizedContactEmail == nil
    }

    private var canPublish: Bool {
        guard let port = Int(targetPort) else { return false }
        guard challengeMode.challenge(credentialID: dnsCredentialID) != nil else { return false }
        return !isWorking
            && !gateway.isBusy
            && !serviceLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (1 ... 65_535).contains(port)
            && (!requiresContactEmail || normalizedContactEmail != nil)
            && store.selectedConfig != nil
            && gateway.magicDNSState == .ready
            && selectedTarget != nil
    }

    init(preferredTargetPeerID: String? = nil) {
        self.preferredTargetPeerID = preferredTargetPeerID
        _selectedTargetPeerID = State(initialValue: preferredTargetPeerID ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Publish Service")
                    .font(.title3)
                    .bold()
                Text("Expose an HTTP port from \(targetDomain) through HTTPS.")
                    .foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    Text("Target Member")
                        .foregroundStyle(.secondary)
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
                        .disabled(isWorking)
                    }
                }
                GridRow {
                    Text("Service Name")
                        .foregroundStyle(.secondary)
                    TextField("abc", text: $serviceLabel)
                        .textFieldStyle(.glassField)
                        .focused($focusedField, equals: .serviceLabel)
                        .disabled(isWorking)
                }
                GridRow {
                    Text("Port")
                        .foregroundStyle(.secondary)
                    TextField("3000", text: $targetPort)
                        .textFieldStyle(.glassField)
                        .focused($focusedField, equals: .targetPort)
                        .disabled(isWorking)
                }
                if requiresContactEmail {
                    GridRow {
                        Text("Certificate Email")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("name@example.com", text: $contactEmail)
                                .textFieldStyle(.glassField)
                                .focused($focusedField, equals: .contactEmail)
                                .disabled(isWorking)
                            if contactEmailIsInvalid {
                                Label("Enter a valid email address.", systemImage: "exclamationmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            } else {
                                Text("Used by the certificate authority for security and renewal notices.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .gridColumnAlignment(.leading)

            PublishedServiceHTTPSOptions(
                isExpanded: $showsHTTPSOptions,
                certificateAuthority: $certificateAuthority,
                challengeMode: $challengeMode,
                dnsCredentialID: $dnsCredentialID,
                dnsCredentials: gateway.dnsCredentials,
                onManageDNSCredentials: openGatewaySettings
            )

            if selectedTarget != nil {
                PublishedServicePreview(
                    publicURL: publicURL,
                    target: targetSummary,
                    copyAction: copyPublicURL
                )
            }

            if let errorMessage {
                ErrorBanner(message: errorMessage)
            }

            HStack(spacing: 4) {
                Text("By publishing, you agree to \(certificateAuthority.label)'s certificate terms.")
                Link("View terms", destination: certificateAuthority.termsURL)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel, action: dismiss.callAsFunction)
                    .disabled(isWorking)
                    .keyboardShortcut(.cancelAction)
                Button("Publish", systemImage: "checkmark.shield", action: publish)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canPublish)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520)
        .task(prepare)
        .onChange(of: targetOptionIDs) { _, _ in
            reconcileTargetSelection()
        }
    }

    private func prepare() async {
        reconcileTargetSelection()
        focusedField = .serviceLabel
    }

    private func reconcileTargetSelection() {
        selectedTargetPeerID = PublishedServiceTargetOption.initialPeerID(
            in: targetOptions,
            preferredPeerID: selectedTargetPeerID.nilIfEmpty ?? preferredTargetPeerID
        ) ?? ""
    }

    private func publish() {
        Task {
            isWorking = true
            errorMessage = nil
            defer { isWorking = false }
            do {
                guard gateway.magicDNSState == .ready else {
                    throw GatewayConfigurationValidationError.invalid(
                        "Wait for Magic DNS to become ready before publishing a service."
                    )
                }
                guard let config = store.selectedConfig,
                      let port = Int(targetPort),
                      let selectedTarget
                else {
                    throw GatewayConfigurationValidationError.invalid(
                        "Select a running EasyTier network and enter a valid target port."
                    )
                }
                guard let challenge = challengeMode.challenge(credentialID: dnsCredentialID) else {
                    throw GatewayConfigurationValidationError.invalid(
                        "Choose a DNS credential for DNS-01."
                    )
                }
                _ = try await gateway.createService(
                    networkConfigID: config.instance_id,
                    targetPeerID: selectedTarget.peerID,
                    targetInstanceID: selectedTarget.instanceID,
                    targetHostname: selectedTarget.hostname,
                    magicDNSSuffix: gateway.appliedMagicDNSSuffix
                        ?? store.magicDNSSettings.dnsSuffix,
                    serviceLabel: serviceLabel,
                    targetPort: port,
                    contactEmail: requiresContactEmail ? normalizedContactEmail : nil,
                    certificatePolicy: GatewayCertificatePolicy(
                        authority: certificateAuthority,
                        challenge: challenge
                    )
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
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(publicURL, forType: .string)
    }
}
