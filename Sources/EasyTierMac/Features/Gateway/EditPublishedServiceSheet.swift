import EasyTierShared
import SwiftUI

struct EditPublishedServiceSheet: View {
    @Environment(\.dismiss) private var dismiss

    let service: GatewayPublishedService
    let targetOptions: [PublishedServiceTargetOption]
    let sslProvider: PublishedServiceSSLProvider
    let onConfigureSSL: () -> Void
    let onSave: (PublishedServiceTargetOption, Int) -> Void

    @State private var portText: String
    @State private var selectedTargetPeerID: String
    @FocusState private var portFocused: Bool

    private var parsedPort: Int? {
        guard let port = Int(portText), (1 ... 65_535).contains(port) else { return nil }
        return port
    }

    private var canSave: Bool {
        guard parsedPort != nil, let selectedTarget else { return false }
        return parsedPort != service.targetPort
            || selectedTarget.peerID != service.targetPeerID
            || selectedTarget.instanceID != service.targetInstanceID
            || selectedTarget.hostname != service.lastKnownTargetHostname
    }

    private var selectedTarget: PublishedServiceTargetOption? {
        targetOptions.first { $0.peerID == selectedTargetPeerID }
    }

    init(
        service: GatewayPublishedService,
        targetOptions: [PublishedServiceTargetOption],
        sslProvider: PublishedServiceSSLProvider,
        onConfigureSSL: @escaping () -> Void,
        onSave: @escaping (PublishedServiceTargetOption, Int) -> Void
    ) {
        self.service = service
        self.targetOptions = targetOptions
        self.sslProvider = sslProvider
        self.onConfigureSSL = onConfigureSSL
        self.onSave = onSave
        _portText = State(initialValue: String(service.targetPort))
        let currentPeerID = targetOptions.first { option in
            guard let targetInstanceID = service.targetInstanceID else {
                return option.peerID == service.targetPeerID
            }
            return option.instanceID == targetInstanceID
        }?.peerID ?? service.targetPeerID
        _selectedTargetPeerID = State(initialValue: currentPeerID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Edit Service")
                    .font(.title3)
                    .bold()
                Text(service.publicHostname)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            SettingsCard {
                SettingsInlineRow("Proxy IPv4") {
                    Picker("Proxy IPv4", selection: $selectedTargetPeerID) {
                        ForEach(targetOptions) { target in
                            Text(target.label)
                                .tag(target.peerID)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 250)
                    .help("Choose the EasyTier member that receives this service's proxy traffic.")
                }
                SettingsRowDivider()
                SettingsInlineRow("Port") {
                    TextField("Port", text: $portText)
                        .textFieldStyle(.glassField)
                        .font(.body.monospacedDigit())
                        .frame(width: 120)
                        .focused($portFocused)
                        .onSubmit(save)
                }
                SettingsRowDivider()
                SettingsInlineRow("SSL") {
                    HStack(spacing: 8) {
                        Text(sslProvider.label)
                            .foregroundStyle(sslProvider.isSecure ? .primary : .secondary)
                        Button("Settings…", systemImage: "lock.shield", action: configureSSL)
                            .buttonStyle(.borderless)
                    }
                }
            }

            HStack {
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save", systemImage: "checkmark", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 420)
        .task {
            portFocused = true
        }
    }

    private func save() {
        guard let parsedPort, let selectedTarget, canSave else { return }
        onSave(selectedTarget, parsedPort)
        dismiss()
    }

    private func configureSSL() {
        dismiss()
        onConfigureSSL()
    }
}
