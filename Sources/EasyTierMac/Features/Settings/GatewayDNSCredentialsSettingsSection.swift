import EasyTierShared
import SwiftUI

struct GatewayDNSCredentialsSettingsSection: View {
    let gateway: GatewayRuntimeController

    @State private var editingCredential: GatewayDNSCredentialDescriptor?
    @State private var isAddingCredential = false
    @State private var errorMessage: String?
    @State private var defaultCredentialID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let errorMessage {
                ErrorBanner(message: errorMessage)
            }

            CardSection(
                "DNS Credentials",
                systemImage: "network.badge.shield.half.filled",
                footer: "DNS credentials are stored in Keychain and are used only for DNS-01 certificate validation."
            ) {
                SettingsInlineRow("Default") {
                    Picker("Default DNS Credential", selection: $defaultCredentialID) {
                        Text("None").tag(Optional<String>.none)
                        ForEach(gateway.dnsCredentials) { credential in
                            Text(credential.label).tag(Optional(credential.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 240)
                    .onChange(of: defaultCredentialID) { _, newValue in
                        updateDefaultCredential(newValue)
                    }
                }
                SettingsRowDivider()

                if gateway.dnsCredentials.isEmpty {
                    Text("No DNS credentials")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(gateway.dnsCredentials) { credential in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(credential.label)
                                Text(credential.provider.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 12)
                            Button("Edit", systemImage: "pencil") {
                                editingCredential = credential
                            }
                            .buttonStyle(.borderless)
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                delete(credential)
                            }
                            .buttonStyle(.borderless)
                        }
                        if credential.id != gateway.dnsCredentials.last?.id {
                            SettingsRowDivider()
                        }
                    }
                }
                SettingsRowDivider()
                HStack {
                    Spacer(minLength: 0)
                    Button("Add Credential", systemImage: "plus") {
                        isAddingCredential = true
                    }
                }
            }
        }
        .sheet(isPresented: $isAddingCredential) {
            GatewayDNSCredentialEditor(gateway: gateway, credential: nil)
        }
        .sheet(item: $editingCredential) { credential in
            GatewayDNSCredentialEditor(gateway: gateway, credential: credential)
        }
        .task(id: gateway.defaultDNSCredentialID) {
            defaultCredentialID = gateway.defaultDNSCredentialID
        }
    }

    private func delete(_ credential: GatewayDNSCredentialDescriptor) {
        Task {
            do {
                try await gateway.deleteDNSCredential(id: credential.id)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func updateDefaultCredential(_ id: String?) {
        guard id != gateway.defaultDNSCredentialID else { return }
        Task {
            do {
                try await gateway.setDefaultDNSCredential(id: id)
                errorMessage = nil
            } catch {
                defaultCredentialID = gateway.defaultDNSCredentialID
                errorMessage = error.localizedDescription
            }
        }
    }
}

extension GatewayDNSProvider {
    var displayName: String {
        switch self {
        case .cloudflare: "Cloudflare"
        case .aliyun: "Alibaba Cloud DNS"
        }
    }
}
