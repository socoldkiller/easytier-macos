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
    @State private var draftID: String?
    @State private var draftTarget: PublishedServiceTargetOption?
    @State private var challengeMode = PublishedServiceChallengeMode.automatic
    @State private var dnsCredentialID: String?
    @State private var isWorking = false
    @State private var errorMessage: String?

    private enum Field: Hashable {
        case serviceLabel
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

    private var effectiveTarget: PublishedServiceTargetOption? {
        draftTarget ?? selectedTarget
    }

    private var targetDomain: String {
        guard let effectiveTarget else { return "member" }
        return MagicDNSDisplay.memberDomain(
            hostname: effectiveTarget.hostname,
            config: store.selectedConfig,
            settings: store.magicDNSSettings
        ) ?? "\(effectiveTarget.hostname).\(trimmedDNSSuffix)"
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

    private var canPublish: Bool {
        guard let port = Int(targetPort) else { return false }
        guard challengeMode.challenge(credentialID: dnsCredentialID) != nil else { return false }
        return !isWorking
            && !gateway.isBusy
            && !serviceLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (1 ... 65_535).contains(port)
            && gateway.isTLSConfigured
            && store.selectedConfig != nil
            && gateway.magicDNSState == .ready
            && effectiveTarget != nil
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
                        .disabled(draftID != nil || isWorking)
                    }
                }
                GridRow {
                    Text("Service Name")
                        .foregroundStyle(.secondary)
                    TextField("abc", text: $serviceLabel)
                        .textFieldStyle(.glassField)
                        .focused($focusedField, equals: .serviceLabel)
                        .disabled(draftID != nil || isWorking)
                }
                GridRow {
                    Text("Certificate")
                        .foregroundStyle(.secondary)
                    Picker("Certificate Challenge", selection: $challengeMode) {
                        ForEach(PublishedServiceChallengeMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                }
                if challengeMode == .automatic || challengeMode == .dns01 {
                    GridRow {
                        Text(challengeMode == .automatic ? "DNS Fallback" : "DNS Credential")
                            .foregroundStyle(.secondary)
                        Picker("DNS Credential", selection: $dnsCredentialID) {
                            if challengeMode == .automatic {
                                Text("None").tag(String?.none)
                            }
                            ForEach(gateway.dnsCredentials) { credential in
                                Text("\(credential.label) · \(credential.provider.displayName)")
                                    .tag(Optional(credential.id))
                            }
                        }
                        .labelsHidden()
                    }
                }
                GridRow {
                    Text("Port")
                        .foregroundStyle(.secondary)
                    TextField("3000", text: $targetPort)
                        .textFieldStyle(.glassField)
                        .focused($focusedField, equals: .targetPort)
                        .disabled(draftID != nil || isWorking)
                }
            }
            .gridColumnAlignment(.leading)

            if effectiveTarget != nil {
                PublishedServicePreview(
                    publicURL: publicURL,
                    target: targetSummary,
                    copyAction: copyPublicURL
                )
            }

            if !gateway.isTLSConfigured {
                GatewayTLSRequirementBanner(action: openGatewaySettings)
            } else if !gateway.desiredEnabled {
                Label(
                    "Gateway is off. This service will become available after you turn it on in General.",
                    systemImage: "power.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let errorMessage {
                ErrorBanner(message: errorMessage)
            }

            HStack {
                if draftID != nil, errorMessage != nil {
                    Label("Service draft saved", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
        guard draftID == nil else { return }
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
                guard gateway.isTLSConfigured else {
                    throw GatewayConfigurationValidationError.invalid(
                        "Configure SSL in Settings > Gateway before publishing a service."
                    )
                }
                guard gateway.magicDNSState == .ready else {
                    throw GatewayConfigurationValidationError.invalid(
                        "Wait for Magic DNS to become ready before publishing a service."
                    )
                }
                guard let config = store.selectedConfig,
                      let port = Int(targetPort),
                      let effectiveTarget
                else {
                    throw GatewayConfigurationValidationError.invalid(
                        "Select a running EasyTier network and enter a valid target port."
                    )
                }
                let serviceID: String
                guard let challenge = challengeMode.challenge(credentialID: dnsCredentialID) else {
                    throw GatewayConfigurationValidationError.invalid(
                        "Choose a DNS credential for DNS-01."
                    )
                }
                if let draftID {
                    serviceID = draftID
                } else {
                    let draft = try await gateway.createDraft(
                        networkConfigID: config.instance_id,
                        targetPeerID: effectiveTarget.peerID,
                        targetInstanceID: effectiveTarget.instanceID,
                        targetHostname: effectiveTarget.hostname,
                        magicDNSSuffix: gateway.appliedMagicDNSSuffix
                            ?? store.magicDNSSettings.dnsSuffix,
                        serviceLabel: serviceLabel,
                        targetPort: port
                    )
                    draftID = draft.id
                    draftTarget = effectiveTarget
                    serviceID = draft.id
                }
                try await gateway.updateChallenge(serviceID: serviceID, challenge: challenge)
                try await gateway.setServiceEnabled(true, serviceID: serviceID)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func openGatewaySettings() {
        appContext.settings.request(.gateway)
        dismiss()
        openWindow(id: EasyTierWindowID.settings)
    }

    private func copyPublicURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(publicURL, forType: .string)
    }
}
