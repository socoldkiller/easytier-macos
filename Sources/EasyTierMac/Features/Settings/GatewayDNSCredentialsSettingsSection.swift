import EasyTierShared
import SwiftUI

struct GatewayDNSCredentialsSettingsSection: View {
    let gateway: GatewayRuntimeController

    @State private var editingCredential: GatewayDNSCredentialDescriptor?
    @State private var credentialPendingDeletion: GatewayDNSCredentialDescriptor?
    @State private var credentialPendingDefaultID: String?
    @State private var isAddingCredential = false
    @State private var errorMessage: String?

    var body: some View {
        Section {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }

            if gateway.dnsCredentials.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("No credentials configured")
                    Text("Add a DNS provider to issue wildcard certificates.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(gateway.dnsCredentials) { credential in
                    GatewayDNSCredentialSettingsRow(
                        credential: credential,
                        isDefault: credential.id == gateway.defaultDNSCredentialID,
                        isChangingDefault: credential.id == credentialPendingDefaultID,
                        setDefaultAction: {
                            updateDefaultCredential(
                                credential.id,
                                sourceCredentialID: credential.id
                            )
                        },
                        clearDefaultAction: {
                            updateDefaultCredential(
                                nil,
                                sourceCredentialID: credential.id
                            )
                        },
                        editAction: { editingCredential = credential },
                        deleteAction: { credentialPendingDeletion = credential }
                    )
                }
            }

            Button("Add Credential…", systemImage: "plus.circle", action: beginAddingCredential)
                .buttonStyle(.plain)
                .font(.body)
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
        .alert(
            "Delete DNS Credential?",
            isPresented: deletionAlertPresented,
            presenting: credentialPendingDeletion
        ) { credential in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                delete(credential)
            }
        } message: { credential in
            Text(deletionMessage(for: credential))
        }
    }

    private var deletionAlertPresented: Binding<Bool> {
        Binding(
            get: { credentialPendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    credentialPendingDeletion = nil
                }
            }
        )
    }

    private func delete(_ credential: GatewayDNSCredentialDescriptor) {
        Task {
            do {
                try await gateway.deleteDNSCredential(id: credential.id)
                credentialPendingDeletion = nil
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func deletionMessage(for credential: GatewayDNSCredentialDescriptor) -> String {
        let defaultWarning = credential.id == gateway.defaultDNSCredentialID
            ? " It is currently the default credential."
            : ""
        return "“\(credential.label)” will be removed from EasyTier and Keychain.\(defaultWarning) Automatic certificate issuance may stop until another credential is selected."
    }

    private func beginAddingCredential() {
        isAddingCredential = true
    }

    private func updateDefaultCredential(_ id: String?, sourceCredentialID: String) {
        guard id != gateway.defaultDNSCredentialID, credentialPendingDefaultID == nil else {
            return
        }
        Task {
            credentialPendingDefaultID = sourceCredentialID
            defer { credentialPendingDefaultID = nil }
            do {
                try await gateway.setDefaultDNSCredential(id: id)
                errorMessage = nil
            } catch {
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
