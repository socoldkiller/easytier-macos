import EasyTierShared
import SwiftUI

struct PublishedServiceHTTPSOptions: View {
    @Binding var isExpanded: Bool
    @Binding var certificateAuthority: GatewayCertificateAuthority
    @Binding var challengeMode: PublishedServiceChallengeMode
    @Binding var dnsCredentialID: String?

    let dnsCredentials: [GatewayDNSCredentialDescriptor]
    let status: PublishedServiceSSLProvider?
    let isDisabled: Bool
    let onManageDNSCredentials: () -> Void

    private var credentialIDs: [String] {
        dnsCredentials.map(\.id)
    }

    private var statusSystemImage: String {
        switch status {
        case .unavailable: "exclamationmark.triangle.fill"
        case .managedHTTPS: "checkmark.circle.fill"
        case .requesting: "clock.arrow.circlepath"
        case nil: "lock.shield"
        }
    }

    private var statusStyle: Color {
        switch status {
        case .unavailable: .orange
        case .managedHTTPS: .green
        case .requesting: .blue
        case nil: .secondary
        }
    }

    init(
        isExpanded: Binding<Bool>,
        certificateAuthority: Binding<GatewayCertificateAuthority>,
        challengeMode: Binding<PublishedServiceChallengeMode>,
        dnsCredentialID: Binding<String?>,
        dnsCredentials: [GatewayDNSCredentialDescriptor],
        status: PublishedServiceSSLProvider? = nil,
        isDisabled: Bool = false,
        onManageDNSCredentials: @escaping () -> Void
    ) {
        _isExpanded = isExpanded
        _certificateAuthority = certificateAuthority
        _challengeMode = challengeMode
        _dnsCredentialID = dnsCredentialID
        self.dnsCredentials = dnsCredentials
        self.status = status
        self.isDisabled = isDisabled
        self.onManageDNSCredentials = onManageDNSCredentials
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: toggleExpansion) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(isExpanded ? .degrees(90) : .zero)
                        .imageScale(.small)
                        .frame(width: 14)

                    Image(systemName: "lock.shield")
                        .foregroundStyle(.tint)
                        .imageScale(.small)

                    Text("Certificate Options")
                        .foregroundStyle(.secondary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if isExpanded {
                if let status, case .unavailable = status {
                    PublishedServiceFormRow("Status", systemImage: "exclamationmark.triangle") {
                        HStack {
                            Image(systemName: statusSystemImage)
                                .foregroundStyle(statusStyle)
                            VStack(alignment: .leading) {
                                Text(status.label)
                                Text(status.helpText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                PublishedServiceFormRow("Authority", systemImage: "building.columns") {
                    Picker("Certificate Authority", selection: $certificateAuthority) {
                        ForEach(GatewayCertificateAuthority.allCases, id: \.self) { authority in
                            Text(authority.label).tag(authority)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 204, alignment: .leading)
                }

                PublishedServiceFormRow("Validation", systemImage: "checkmark.shield") {
                    Picker("Certificate Validation", selection: $challengeMode) {
                        ForEach(PublishedServiceChallengeMode.allCases) { mode in
                            Text(mode.optionLabel).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 204, alignment: .leading)
                }

                if challengeMode == .dns01 {
                    PublishedServiceFormRow("Credential", systemImage: "key") {
                        if dnsCredentials.isEmpty {
                            Button(
                                "Manage DNS Credentials…",
                                systemImage: "key",
                                action: onManageDNSCredentials
                            )
                        } else {
                            Picker("DNS Credential", selection: $dnsCredentialID) {
                                ForEach(dnsCredentials) { credential in
                                    Text("\(credential.label) · \(credential.provider.displayName)")
                                        .tag(Optional(credential.id))
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 204, alignment: .leading)
                        }
                    }
                }

                HStack(spacing: 4) {
                    Text("Uses \(certificateAuthority.label)'s certificate service.")
                    Link("Terms", destination: certificateAuthority.termsURL)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 124)
            }
        }
        .disabled(isDisabled)
        .task {
            reconcileDNSCredentialSelection()
        }
        .onChange(of: challengeMode) { _, _ in
            reconcileDNSCredentialSelection()
        }
        .onChange(of: credentialIDs) { _, _ in
            reconcileDNSCredentialSelection()
        }
    }

    private func toggleExpansion() {
        isExpanded.toggle()
    }

    private func reconcileDNSCredentialSelection() {
        guard challengeMode == .dns01 else { return }
        if let dnsCredentialID, credentialIDs.contains(dnsCredentialID) {
            return
        }
        dnsCredentialID = dnsCredentials.first?.id
    }
}
