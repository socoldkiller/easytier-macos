import EasyTierShared
import SwiftUI

struct EditPublishedServiceSheet: View {
    @Environment(\.dismiss) private var dismiss

    let service: GatewayPublishedService
    let targetOptions: [PublishedServiceTargetOption]
    let dnsCredentials: [GatewayDNSCredentialDescriptor]
    let certificate: GatewayManagedCertificate
    let defaultDNSCredentialID: String?
    let sslProvider: PublishedServiceSSLProvider
    let onManageDNSCredentials: () -> Void
    let onSave: @MainActor (
        PublishedServiceTargetOption,
        Int,
        GatewayServiceCertificateSelection
    ) async throws -> Void

    @State private var portText: String
    @State private var selectedTargetPeerID: String
    @State private var certificateMode: PublishedServiceCertificateMode
    @State private var certificateAuthority: GatewayCertificateAuthority
    @State private var challengeMode: PublishedServiceChallengeMode
    @State private var dnsCredentialID: String?
    @State private var showsHTTPSOptions = false
    @State private var hasEditedPort = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @FocusState private var portIsFocused: Bool

    private var parsedPort: Int? {
        PublishedServiceFormValidation.parsedPort(portText)
    }

    private var portError: String? {
        PublishedServiceFormValidation.portError(portText)
    }

    private var selectedTarget: PublishedServiceTargetOption? {
        targetOptions.first { $0.peerID == selectedTargetPeerID }
    }

    private var certificateSelection: GatewayServiceCertificateSelection? {
        if certificateMode == .automatic {
            return defaultDNSCredentialID == nil ? nil : .automatic
        }
        guard let challenge = challengeMode.challenge(credentialID: dnsCredentialID) else {
            return nil
        }
        return .custom(authority: certificateAuthority, challenge: challenge)
    }

    private var canSave: Bool {
        guard !isWorking,
              let parsedPort,
              let selectedTarget,
              let certificateSelection
        else {
            return false
        }
        return PublishedServiceFormValidation.editHasChanges(
            service: service,
            selectedTarget: selectedTarget,
            port: parsedPort,
            certificateSelection: certificateSelection,
            currentSelection: Self.selection(for: certificate)
        )
    }

    init(
        service: GatewayPublishedService,
        targetOptions: [PublishedServiceTargetOption],
        dnsCredentials: [GatewayDNSCredentialDescriptor],
        certificate: GatewayManagedCertificate,
        defaultDNSCredentialID: String?,
        sslProvider: PublishedServiceSSLProvider,
        onManageDNSCredentials: @escaping () -> Void,
        onSave: @escaping @MainActor (
            PublishedServiceTargetOption,
            Int,
            GatewayServiceCertificateSelection
        ) async throws -> Void
    ) {
        self.service = service
        self.targetOptions = targetOptions
        self.dnsCredentials = dnsCredentials
        self.certificate = certificate
        self.defaultDNSCredentialID = defaultDNSCredentialID
        self.sslProvider = sslProvider
        self.onManageDNSCredentials = onManageDNSCredentials
        self.onSave = onSave
        _portText = State(initialValue: String(service.targetPort))
        let currentPeerID = targetOptions.first { option in
            guard let targetInstanceID = service.targetInstanceID else {
                return option.peerID == service.targetPeerID
            }
            return option.instanceID == targetInstanceID
        }?.peerID ?? service.targetPeerID
        _selectedTargetPeerID = State(initialValue: currentPeerID)
        switch certificate.strategy {
        case .automaticWildcard:
            _certificateMode = State(initialValue: .automatic)
            _certificateAuthority = State(initialValue: .letsEncrypt)
            _challengeMode = State(initialValue: .http01)
            _dnsCredentialID = State(initialValue: nil)
        case let .custom(authority, challenge):
            _certificateMode = State(initialValue: .custom)
            _certificateAuthority = State(initialValue: authority)
            _challengeMode = State(initialValue: PublishedServiceChallengeMode(challenge))
            _dnsCredentialID = State(initialValue: challenge.dnsCredentialID)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                PublishedServiceSheetHeader(
                    title: "Edit Service",
                    subtitle: service.publicHostname
                )

                VStack(alignment: .leading, spacing: 14) {
                    PublishedServiceFormRow("Destination", systemImage: "arrow.right") {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
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
                                .help("Choose the member that receives this service's proxy traffic.")

                                Text(":")
                                    .foregroundStyle(.tertiary)

                                TextField("Port", text: $portText)
                                    .labelsHidden()
                                    .textFieldStyle(.roundedBorder)
                                    .font(.body.monospacedDigit())
                                    .frame(width: 72)
                                    .focused($portIsFocused)
                                    .disabled(isWorking)
                                    .onSubmit(save)
                            }

                            if hasEditedPort, let portError {
                                PublishedServiceFieldMessage(
                                    message: portError,
                                    showsError: true
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
                        dnsCredentials: dnsCredentials,
                        automaticDomain: automaticDomain,
                        defaultDNSCredentialID: defaultDNSCredentialID,
                        status: sslProvider,
                        isDisabled: isWorking,
                        onManageDNSCredentials: onManageDNSCredentials
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
                Button(action: save) {
                    HStack {
                        if isWorking {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(isWorking ? "Saving…" : "Save")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .frame(width: 500)
        .controlSize(.regular)
        .task {
            portIsFocused = true
        }
        .onChange(of: portText) { oldValue, newValue in
            if oldValue != newValue {
                hasEditedPort = true
            }
        }
    }

    private func save() {
        guard canSave,
              let parsedPort,
              let selectedTarget,
              let certificateSelection
        else {
            hasEditedPort = true
            return
        }

        Task {
            isWorking = true
            errorMessage = nil
            defer { isWorking = false }
            do {
                try await onSave(selectedTarget, parsedPort, certificateSelection)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var automaticDomain: String {
        let suffix = service.publicDNSSuffix.hasSuffix(".")
            ? String(service.publicDNSSuffix.dropLast())
            : service.publicDNSSuffix
        return "*.\(service.publicNodeLabel).\(suffix)"
    }

    private static func selection(
        for certificate: GatewayManagedCertificate
    ) -> GatewayServiceCertificateSelection {
        switch certificate.strategy {
        case .automaticWildcard:
            .automatic
        case let .custom(authority, challenge):
            .custom(authority: authority, challenge: challenge)
        }
    }
}
