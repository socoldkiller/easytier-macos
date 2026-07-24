import EasyTierShared
import SwiftUI

struct GatewayDNSCredentialEditor: View {
    private enum FocusedField: Hashable {
        case domain
        case apiToken
        case accessKeyID
        case accessKeySecret
    }

    @Environment(\.dismiss) private var dismiss

    let gateway: GatewayRuntimeController
    let binding: GatewayDNSZoneBinding?

    @State private var domain: String
    @State private var provider: GatewayDNSProvider
    @State private var apiToken = ""
    @State private var accessKeyID = ""
    @State private var accessKeySecret = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: FocusedField?

    private var credential: GatewayDNSCredentialDescriptor? {
        guard let binding else { return nil }
        return gateway.dnsCredentials.first { $0.id == binding.credentialID }
    }

    private var title: String {
        binding == nil ? "Add Domain" : "Update Credential"
    }

    private var primaryActionTitle: String {
        binding == nil ? "Add" : "Save"
    }

    private var normalizedSuffix: String? {
        try? MagicDNSSettings.normalizedDNSSuffix(domain)
    }

    private var displayDomain: String {
        let suffix = normalizedSuffix ?? domain
        return suffix.hasSuffix(".") ? String(suffix.dropLast()) : suffix
    }

    private var canSave: Bool {
        guard normalizedSuffix != nil else { return false }
        return switch provider {
        case .cloudflare: !apiToken.isEmpty
        case .aliyun: !accessKeyID.isEmpty && !accessKeySecret.isEmpty
        }
    }

    init(gateway: GatewayRuntimeController, binding: GatewayDNSZoneBinding?) {
        self.gateway = gateway
        self.binding = binding
        let credential = binding.flatMap { binding in
            gateway.dnsCredentials.first { $0.id == binding.credentialID }
        }
        let suffix = binding?.dnsSuffix ?? ""
        _domain = State(initialValue: suffix.hasSuffix(".") ? String(suffix.dropLast()) : suffix)
        _provider = State(initialValue: credential?.provider ?? .cloudflare)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                PublishedServiceSheetHeader(
                    title: title,
                    subtitle: "Credentials are stored securely in Keychain"
                )

                VStack(alignment: .leading, spacing: 14) {
                    PublishedServiceFormRow("Domain", systemImage: "globe") {
                        if binding == nil {
                            TextField("example.com", text: $domain)
                                .labelsHidden()
                                .textFieldStyle(.glassField)
                                .frame(width: 280)
                                .focused($focusedField, equals: .domain)
                                .onSubmit(advanceFromDomain)
                        } else {
                            Text(displayDomain)
                                .foregroundStyle(.secondary)
                                .frame(width: 280, alignment: .leading)
                        }
                    }

                    PublishedServiceFormRow("Provider", systemImage: "building.2") {
                        if binding == nil {
                            Picker("DNS Provider", selection: $provider) {
                                ForEach(
                                    [GatewayDNSProvider.cloudflare, .aliyun],
                                    id: \.self
                                ) { provider in
                                    Text(provider.displayName).tag(provider)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 280, alignment: .leading)
                        } else {
                            Text(provider.displayName)
                                .foregroundStyle(.secondary)
                                .frame(width: 280, alignment: .leading)
                        }
                    }

                    switch provider {
                    case .cloudflare:
                        PublishedServiceFormRow("API Token", systemImage: "key") {
                            SecureField("Required", text: $apiToken)
                                .labelsHidden()
                                .textFieldStyle(.glassField)
                                .frame(width: 280)
                                .focused($focusedField, equals: .apiToken)
                                .onSubmit(submitIfPossible)
                        }
                    case .aliyun:
                        PublishedServiceFormRow("AccessKey ID", systemImage: "person.text.rectangle") {
                            TextField("Required", text: $accessKeyID)
                                .labelsHidden()
                                .textFieldStyle(.glassField)
                                .frame(width: 280)
                                .focused($focusedField, equals: .accessKeyID)
                                .onSubmit { focusedField = .accessKeySecret }
                        }
                        PublishedServiceFormRow("Secret", systemImage: "key.fill") {
                            SecureField("Required", text: $accessKeySecret)
                                .labelsHidden()
                                .textFieldStyle(.glassField)
                                .frame(width: 280)
                                .focused($focusedField, equals: .accessKeySecret)
                                .onSubmit(submitIfPossible)
                        }
                    }
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
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                Button(action: save) {
                    HStack {
                        if isWorking {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(isWorking ? "Saving…" : primaryActionTitle)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking || !canSave)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .frame(width: 500)
        .controlSize(.regular)
        .task {
            await loadSecret()
            await Task.yield()
            focusedField = binding == nil ? .domain : firstSecretField
        }
    }

    private var firstSecretField: FocusedField {
        switch provider {
        case .cloudflare: .apiToken
        case .aliyun: .accessKeyID
        }
    }

    private func advanceFromDomain() {
        focusedField = firstSecretField
    }

    private func submitIfPossible() {
        guard canSave else { return }
        save()
    }

    private func loadSecret() async {
        guard let credential else { return }
        do {
            switch try await gateway.loadDNSCredentialSecret(id: credential.id) {
            case let .cloudflare(apiToken):
                self.apiToken = apiToken
            case let .aliyun(accessKeyID, accessKeySecret):
                self.accessKeyID = accessKeyID
                self.accessKeySecret = accessKeySecret
            case nil:
                break
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() {
        Task {
            isWorking = true
            defer { isWorking = false }
            guard let suffix = normalizedSuffix else { return }
            let credentialID = credential?.id ?? UUID().uuidString.lowercased()
            let descriptor = GatewayDNSCredentialDescriptor(
                id: credentialID,
                provider: provider,
                label: String(suffix.dropLast()),
                revision: credential?.revision ?? 1
            )
            let zoneBinding = GatewayDNSZoneBinding(
                id: binding?.id ?? UUID().uuidString.lowercased(),
                dnsSuffix: suffix,
                credentialID: credentialID
            )
            let secret: GatewayCredentialSecret = switch provider {
            case .cloudflare:
                .cloudflare(apiToken: apiToken)
            case .aliyun:
                .aliyun(accessKeyID: accessKeyID, accessKeySecret: accessKeySecret)
            }
            do {
                try await gateway.saveDNSDomain(
                    binding: zoneBinding,
                    descriptor: descriptor,
                    secret: secret
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
