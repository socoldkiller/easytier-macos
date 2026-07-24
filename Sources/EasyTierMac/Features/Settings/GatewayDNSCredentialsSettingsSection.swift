import EasyTierShared
import SwiftUI

struct GatewayDNSCredentialsSettingsSection: View {
    let gateway: GatewayRuntimeController

    @State private var editingCredential: GatewayDNSCredentialDescriptor?
    @State private var isAddingCredential = false
    @State private var errorMessage: String?
    @State private var defaultCredentialID: String?

    var body: some View {
        Section {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }

            if gateway.dnsCredentials.isEmpty {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No credentials configured")
                        Text("Add a DNS provider to issue wildcard certificates.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Button("Add Credential…") {
                        isAddingCredential = true
                    }
                    .controlSize(.small)
                    .fixedSize()
                }
            } else {
                LabeledContent("Default Credential") {
                    Picker("Default DNS Credential", selection: $defaultCredentialID) {
                        Text("None").tag(Optional<String>.none)
                        ForEach(gateway.dnsCredentials) { credential in
                            Text(credential.label).tag(Optional(credential.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 210)
                    .onChange(of: defaultCredentialID) { _, newValue in
                        updateDefaultCredential(newValue)
                    }
                }

                ForEach(gateway.dnsCredentials) { credential in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(credential.label)
                            Text(credential.provider.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        Menu {
                            Button("Edit", systemImage: "pencil") {
                                editingCredential = credential
                            }
                            Divider()
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                delete(credential)
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                    }
                    .frame(maxWidth: .infinity)
                }

                HStack {
                    Spacer(minLength: 0)
                    Button("Add Credential…") {
                        isAddingCredential = true
                    }
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity)
            }
        } header: {
            Text("DNS Credentials")
        } footer: {
            Text("Credentials are stored in Keychain and used only for DNS-01 certificate validation.")
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
