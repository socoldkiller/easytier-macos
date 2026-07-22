import EasyTierShared
import SwiftUI

struct PublishedServiceHTTPSOptions: View {
    @Binding var isExpanded: Bool
    @Binding var certificateAuthority: GatewayCertificateAuthority
    @Binding var challengeMode: PublishedServiceChallengeMode
    @Binding var dnsCredentialID: String?

    let dnsCredentials: [GatewayDNSCredentialDescriptor]
    let onManageDNSCredentials: () -> Void

    private var credentialIDs: [String] {
        dnsCredentials.map(\.id)
    }

    private var summary: String {
        "\(certificateAuthority.label) · \(challengeMode.label)"
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text("Certificate Authority")
                        .foregroundStyle(.secondary)
                    Picker("Certificate Authority", selection: $certificateAuthority) {
                        ForEach(GatewayCertificateAuthority.allCases, id: \.self) { authority in
                            Text(authority.label).tag(authority)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                GridRow {
                    Text("Validation")
                        .foregroundStyle(.secondary)
                    Picker("Certificate Validation", selection: $challengeMode) {
                        ForEach(PublishedServiceChallengeMode.allCases) { mode in
                            Text(mode.optionLabel).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                if challengeMode == .dns01 {
                    GridRow {
                        Text("DNS Credential")
                            .foregroundStyle(.secondary)
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
                        }
                    }
                }
            }
            .gridColumnAlignment(.leading)
            .padding(.top, 8)

            HStack(spacing: 4) {
                Text("Saving this option uses \(certificateAuthority.label)'s certificate service.")
                Link("View terms", destination: certificateAuthority.termsURL)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
        } label: {
            HStack {
                Label("HTTPS Options", systemImage: "lock.shield")
                Spacer(minLength: 12)
                Text(summary)
                    .foregroundStyle(.secondary)
            }
        }
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

    private func reconcileDNSCredentialSelection() {
        guard challengeMode == .dns01 else { return }
        if let dnsCredentialID, credentialIDs.contains(dnsCredentialID) {
            return
        }
        dnsCredentialID = dnsCredentials.first?.id
    }
}
