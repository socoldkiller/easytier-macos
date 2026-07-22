import EasyTierShared
import SwiftUI

struct EditPublishedServiceSheet: View {
    @Environment(\.dismiss) private var dismiss

    let service: GatewayPublishedService
    let targetOptions: [PublishedServiceTargetOption]
    let dnsCredentials: [GatewayDNSCredentialDescriptor]
    let sslProvider: PublishedServiceSSLProvider
    let onConfigureSSL: () -> Void
    let onSave: (PublishedServiceTargetOption, Int, GatewayCertificatePolicy) -> Void

    @State private var portText: String
    @State private var selectedTargetPeerID: String
    @State private var certificateAuthority: GatewayCertificateAuthority
    @State private var challengeMode: PublishedServiceChallengeMode
    @State private var dnsCredentialID: String?

    private var parsedPort: Int? {
        guard let port = Int(portText), (1 ... 65_535).contains(port) else { return nil }
        return port
    }

    private var canSave: Bool {
        guard parsedPort != nil, let selectedTarget else { return false }
        guard let challenge = challengeMode.challenge(credentialID: dnsCredentialID) else { return false }
        let policy = GatewayCertificatePolicy(
            authority: certificateAuthority,
            challenge: challenge
        )
        return parsedPort != service.targetPort
            || selectedTarget.peerID != service.targetPeerID
            || selectedTarget.instanceID != service.targetInstanceID
            || selectedTarget.hostname != service.lastKnownTargetHostname
            || policy != service.certificatePolicy
    }

    private var selectedTarget: PublishedServiceTargetOption? {
        targetOptions.first { $0.peerID == selectedTargetPeerID }
    }

    private var sslStatusIcon: String {
        switch sslProvider {
        case .unavailable: "exclamationmark.triangle.fill"
        case .managedHTTPS: "checkmark.circle.fill"
        case .requesting: "clock.arrow.circlepath"
        }
    }

    private var sslStatusColor: Color {
        switch sslProvider {
        case .unavailable: .orange
        case .managedHTTPS: .green
        case .requesting: .blue
        }
    }

    init(
        service: GatewayPublishedService,
        targetOptions: [PublishedServiceTargetOption],
        dnsCredentials: [GatewayDNSCredentialDescriptor],
        sslProvider: PublishedServiceSSLProvider,
        onConfigureSSL: @escaping () -> Void,
        onSave: @escaping (
            PublishedServiceTargetOption,
            Int,
            GatewayCertificatePolicy
        ) -> Void
    ) {
        self.service = service
        self.targetOptions = targetOptions
        self.dnsCredentials = dnsCredentials
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
        _certificateAuthority = State(initialValue: service.certificatePolicy.authority)
        _challengeMode = State(
            initialValue: PublishedServiceChallengeMode(service.certificatePolicy.challenge)
        )
        _dnsCredentialID = State(initialValue: service.certificatePolicy.challenge.dnsCredentialID)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                header

                EditServiceSection("Destination", systemImage: "arrow.left.arrow.right") {
                    EditServiceFormRow("Target Member") {
                        Picker("Target Member", selection: $selectedTargetPeerID) {
                            ForEach(targetOptions) { target in
                                Text(target.label)
                                    .tag(target.peerID)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity)
                        .help("Choose the EasyTier member that receives this service's proxy traffic.")
                    }

                    EditServiceRowDivider()

                    EditServiceFormRow("HTTP Port") {
                        HStack(spacing: 8) {
                            TextField("Port", text: $portText)
                                .textFieldStyle(.roundedBorder)
                                .font(.body.monospacedDigit())
                                .frame(width: 112)
                                .onSubmit(save)

                            if !portText.isEmpty, parsedPort == nil {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(.red)
                                    .help("Enter a port from 1 to 65535.")
                            }

                            Spacer(minLength: 0)
                        }
                    }
                }

                EditServiceSection("HTTPS", systemImage: "lock.shield") {
                    EditServiceFormRow("Status") {
                        HStack(spacing: 10) {
                            Image(systemName: sslStatusIcon)
                                .foregroundStyle(sslStatusColor)
                                .frame(width: 16)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(sslProvider.label)
                                Text(sslProvider.helpText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer(minLength: 8)

                            Button("Manage…", action: configureSSL)
                                .controlSize(.small)
                        }
                    }

                    EditServiceRowDivider()

                    EditServiceFormRow("Authority") {
                        Picker("Certificate Authority", selection: $certificateAuthority) {
                            ForEach(GatewayCertificateAuthority.allCases, id: \.self) { authority in
                                Text(authority.label).tag(authority)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity)
                    }

                    EditServiceRowDivider()

                    EditServiceFormRow("Validation") {
                        Picker("Certificate Challenge", selection: $challengeMode) {
                            ForEach(PublishedServiceChallengeMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity)
                    }

                    if challengeMode == .dns01 {
                        EditServiceRowDivider()

                        EditServiceFormRow("DNS Credential") {
                            if dnsCredentials.isEmpty {
                                HStack {
                                    Text("No credentials configured")
                                        .foregroundStyle(.secondary)
                                    Spacer(minLength: 8)
                                    Button("Manage…", action: configureSSL)
                                        .controlSize(.small)
                                }
                            } else {
                                Picker("DNS Credential", selection: $dnsCredentialID) {
                                    ForEach(dnsCredentials) { credential in
                                        Text(credential.label).tag(Optional(credential.id))
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 26)
            .padding(.bottom, 24)

            Divider()

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
        .frame(width: 540)
        .controlSize(.regular)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "network")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 42, height: 42)
                .background(
                    Color.accentColor.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text("Edit Service")
                    .font(.title2.weight(.semibold))

                HStack(spacing: 5) {
                    Image(systemName: "globe")
                        .font(.caption)
                    Text(service.publicHostname)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .help(service.publicHostname)
            }
        }
    }

    private func save() {
        guard let parsedPort,
              let selectedTarget,
              let challenge = challengeMode.challenge(credentialID: dnsCredentialID),
              canSave
        else { return }
        onSave(
            selectedTarget,
            parsedPort,
            GatewayCertificatePolicy(authority: certificateAuthority, challenge: challenge)
        )
        dismiss()
    }

    private func configureSSL() {
        dismiss()
        onConfigureSSL()
    }
}

private struct EditServiceSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    init(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                content
            }
            .background(
                Color.primary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
            }
        }
    }
}

private struct EditServiceFormRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(label)
                .frame(width: 126, alignment: .leading)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct EditServiceRowDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 156)
    }
}
