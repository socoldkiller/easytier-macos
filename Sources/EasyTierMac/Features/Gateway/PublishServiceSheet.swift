import AppKit
import EasyTierShared
import SwiftUI

struct PublishServiceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(AppContext.self) private var appContext
    @FocusState private var focusedField: Field?

    let member: NetworkMemberStatus

    @State private var serviceLabel = ""
    @State private var targetPort = "3000"
    @State private var draftID: String?
    @State private var isWorking = false
    @State private var errorMessage: String?

    private enum Field: Hashable {
        case serviceLabel
        case targetPort
    }

    private var store: EasyTierAppStore { appContext.workspace.store }
    private var gateway: GatewayRuntimeController { appContext.runtime.gateway }

    private var targetDomain: String {
        MagicDNSDisplay.memberDomain(
            hostname: member.hostname,
            config: store.selectedConfig,
            settings: store.magicDNSSettings
        ) ?? "\(member.hostname).\(trimmedDNSSuffix)"
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
        let suffix = store.magicDNSSettings.dnsSuffix
        return suffix.hasSuffix(".") ? String(suffix.dropLast()) : suffix
    }

    private var canPublish: Bool {
        guard let port = Int(targetPort) else { return false }
        return !isWorking
            && !serviceLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (1 ... 65_535).contains(port)
            && gateway.isTLSConfigured
            && store.selectedConfig != nil
            && GatewayTopologyBridge.canPublish(member, store: store)
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
                    Text("Service Name")
                        .foregroundStyle(.secondary)
                    TextField("abc", text: $serviceLabel)
                        .textFieldStyle(.glassField)
                        .focused($focusedField, equals: .serviceLabel)
                        .disabled(draftID != nil || isWorking)
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

            PublishedServicePreview(
                publicURL: publicURL,
                target: targetSummary,
                copyAction: copyPublicURL
            )

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
                Button("Publish", systemImage: "checkmark.shield", action: publish)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canPublish)
            }
        }
        .padding(22)
        .frame(width: 520)
        .task(prepare)
    }

    private func prepare() async {
        focusedField = .serviceLabel
    }

    private func publish() {
        Task {
            isWorking = true
            errorMessage = nil
            defer { isWorking = false }
            do {
                guard gateway.isTLSConfigured else {
                    throw GatewayConfigurationValidationError.invalid(
                        "Configure TLS in Settings > Gateway before publishing a service."
                    )
                }
                guard let config = store.selectedConfig,
                      let port = Int(targetPort)
                else {
                    throw GatewayConfigurationValidationError.invalid(
                        "Select a running EasyTier network and enter a valid target port."
                    )
                }
                let serviceID: String
                if let draftID {
                    serviceID = draftID
                } else {
                    let draft = try await gateway.createDraft(
                        networkConfigID: config.instance_id,
                        targetPeerID: member.peerID,
                        targetHostname: member.hostname,
                        magicDNSSuffix: store.magicDNSSettings.dnsSuffix,
                        serviceLabel: serviceLabel,
                        targetPort: port
                    )
                    draftID = draft.id
                    serviceID = draft.id
                }
                await GatewayTopologyBridge.reconcile(gateway: gateway, store: store)
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
