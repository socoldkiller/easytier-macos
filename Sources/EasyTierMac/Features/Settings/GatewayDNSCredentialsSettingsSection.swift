import EasyTierShared
import SwiftUI

struct GatewayDNSCredentialsSettingsSection: View {
    @Environment(AppContext.self) private var appContext

    let gateway: GatewayRuntimeController

    @State private var editingBinding: GatewayDNSZoneBinding?
    @State private var bindingPendingDeletion: GatewayDNSZoneBinding?
    @State private var bindingPendingDefaultConfirmation: GatewayDNSZoneBinding?
    @State private var bindingPendingDefaultID: String?
    @State private var isAddingDomain = false
    @State private var errorMessage: String?

    var body: some View {
        Section {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }

            if gateway.dnsZoneBindings.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("No domains configured")
                    Text("Add a domain to enable automatic HTTPS certificates.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(gateway.dnsZoneBindings) { binding in
                    if let credential = credential(for: binding) {
                        GatewayDNSCredentialSettingsRow(
                            binding: binding,
                            provider: credential.provider,
                            isDefault: binding.id == gateway.defaultDNSZoneBindingID,
                            isChangingDefault: binding.id == bindingPendingDefaultID,
                            deletionDisabledReason: deletionDisabledReason(for: binding),
                            setDefaultAction: { requestDefault(binding) },
                            editAction: { editingBinding = binding },
                            deleteAction: { bindingPendingDeletion = binding }
                        )
                    }
                }
            }

            Button("Add Domain…", systemImage: "plus.circle") {
                isAddingDomain = true
            }
            .buttonStyle(.plain)
            .font(.body)
        } header: {
            Text("Domains")
        } footer: {
            Text("The default domain is used for Magic DNS and automatic HTTPS certificates.")
        }
        .sheet(isPresented: $isAddingDomain) {
            GatewayDNSCredentialEditor(gateway: gateway, binding: nil)
        }
        .sheet(item: $editingBinding) { binding in
            GatewayDNSCredentialEditor(gateway: gateway, binding: binding)
        }
        .alert(
            "Delete Domain?",
            isPresented: deletionAlertPresented,
            presenting: bindingPendingDeletion
        ) { binding in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { delete(binding) }
        } message: { binding in
            Text("“\(displayDomain(binding))” and its unused Keychain credential will be removed.")
        }
        .alert(
            "Change Default Domain?",
            isPresented: defaultConfirmationPresented,
            presenting: bindingPendingDefaultConfirmation
        ) { binding in
            Button("Cancel", role: .cancel) {}
            Button("Change Domain") { updateDefault(binding.id) }
        } message: { binding in
            Text(defaultChangeMessage(for: binding))
        }
    }

    private var deletionAlertPresented: Binding<Bool> {
        Binding(
            get: { bindingPendingDeletion != nil },
            set: { isPresented in
                if !isPresented { bindingPendingDeletion = nil }
            }
        )
    }

    private var defaultConfirmationPresented: Binding<Bool> {
        Binding(
            get: { bindingPendingDefaultConfirmation != nil },
            set: { isPresented in
                if !isPresented { bindingPendingDefaultConfirmation = nil }
            }
        )
    }

    private func credential(
        for binding: GatewayDNSZoneBinding
    ) -> GatewayDNSCredentialDescriptor? {
        gateway.dnsCredentials.first { $0.id == binding.credentialID }
    }

    private func deletionDisabledReason(for binding: GatewayDNSZoneBinding) -> String? {
        if binding.id == gateway.defaultDNSZoneBindingID {
            return "Choose another default domain before deleting this one."
        }
        let isReferenced = gateway.certificates.contains { certificate in
            switch certificate.strategy {
            case let .automaticWildcard(zoneBindingID):
                zoneBindingID == binding.id
            case let .custom(_, challenge):
                challenge.dnsZoneBindingID == binding.id
            }
        }
        return isReferenced ? "This domain is used by published services." : nil
    }

    private func requestDefault(_ binding: GatewayDNSZoneBinding) {
        guard binding.id != gateway.defaultDNSZoneBindingID,
              bindingPendingDefaultID == nil
        else { return }
        if appContext.workspace.store.hasRunningMagicDNSNetworks {
            bindingPendingDefaultConfirmation = binding
        } else {
            updateDefault(binding.id)
        }
    }

    private func updateDefault(_ id: String) {
        bindingPendingDefaultConfirmation = nil
        Task {
            bindingPendingDefaultID = id
            defer { bindingPendingDefaultID = nil }
            do {
                try await gateway.setDefaultDNSDomain(id: id)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func delete(_ binding: GatewayDNSZoneBinding) {
        Task {
            do {
                try await gateway.deleteDNSDomain(id: binding.id)
                bindingPendingDeletion = nil
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func defaultChangeMessage(for binding: GatewayDNSZoneBinding) -> String {
        let current = gateway.defaultDNSZoneBinding.map(displayDomain) ?? "the current suffix"
        return "Magic DNS will change from \(current) to \(displayDomain(binding)). Running networks must restart to apply the change."
    }

    private func displayDomain(_ binding: GatewayDNSZoneBinding) -> String {
        binding.dnsSuffix.hasSuffix(".")
            ? String(binding.dnsSuffix.dropLast())
            : binding.dnsSuffix
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
