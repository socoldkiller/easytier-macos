import EasyTierShared
import SwiftUI

struct PublishedServiceHTTPSOptions: View {
    @Binding var isExpanded: Bool
    @Binding var certificateMode: PublishedServiceCertificateMode
    @Binding var certificateAuthority: GatewayCertificateAuthority
    @Binding var challengeMode: PublishedServiceChallengeMode
    @Binding var dnsCredentialID: String?

    let dnsCredentials: [GatewayDNSCredentialDescriptor]
    let automaticDomain: String
    let defaultDNSCredentialID: String?
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
        case .httpOnly: "lock.open"
        case nil: "lock.shield"
        }
    }

    private var statusStyle: Color {
        switch status {
        case .unavailable: .orange
        case .managedHTTPS: .green
        case .requesting: .blue
        case .httpOnly: .orange
        case nil: .secondary
        }
    }

    init(
        isExpanded: Binding<Bool>,
        certificateMode: Binding<PublishedServiceCertificateMode>,
        certificateAuthority: Binding<GatewayCertificateAuthority>,
        challengeMode: Binding<PublishedServiceChallengeMode>,
        dnsCredentialID: Binding<String?>,
        dnsCredentials: [GatewayDNSCredentialDescriptor],
        automaticDomain: String,
        defaultDNSCredentialID: String?,
        status: PublishedServiceSSLProvider? = nil,
        isDisabled: Bool = false,
        onManageDNSCredentials: @escaping () -> Void
    ) {
        _isExpanded = isExpanded
        _certificateMode = certificateMode
        _certificateAuthority = certificateAuthority
        _challengeMode = challengeMode
        _dnsCredentialID = dnsCredentialID
        self.dnsCredentials = dnsCredentials
        self.automaticDomain = automaticDomain
        self.defaultDNSCredentialID = defaultDNSCredentialID
        self.status = status
        self.isDisabled = isDisabled
        self.onManageDNSCredentials = onManageDNSCredentials
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
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

                PublishedServiceFormRow("Mode", systemImage: "lock.shield") {
                    Picker("Certificate Mode", selection: $certificateMode) {
                        ForEach(PublishedServiceCertificateMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 204)
                }

                if certificateMode == .automatic {
                    PublishedServiceFormRow("Certificate", systemImage: "checkmark.shield") {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(automaticDomain)
                            Text(defaultDNSCredentialID == nil
                                ? "Choose a default DNS credential in Settings."
                                : "Let's Encrypt, with ZeroSSL fallback")
                                .font(.caption)
                                .foregroundStyle(defaultDNSCredentialID == nil ? .orange : .secondary)
                        }
                    }
                } else {
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
            .padding(.top, 10)
        } label: {
            Label(certificateSummary, systemImage: "lock.shield")
                .foregroundStyle(.secondary)
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

    private var certificateSummary: String {
        switch certificateMode {
        case .automatic:
            "Automatic — \(automaticDomain)"
        case .custom:
            "Custom — \(certificateAuthority.label), \(challengeMode.label)"
        }
    }

    private func reconcileDNSCredentialSelection() {
        guard challengeMode == .dns01 else { return }
        if let dnsCredentialID, credentialIDs.contains(dnsCredentialID) {
            return
        }
        dnsCredentialID = dnsCredentials.first?.id
    }
}
