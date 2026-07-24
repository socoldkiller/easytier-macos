import EasyTierShared
import SwiftUI

struct GatewayDNSCredentialEditor: View {
    private enum FocusedField: Hashable {
        case name
        case apiToken
        case accessKeyID
        case accessKeySecret
    }

    @Environment(\.dismiss) private var dismiss

    let gateway: GatewayRuntimeController
    let credential: GatewayDNSCredentialDescriptor?

    @State private var label: String
    @State private var provider: GatewayDNSProvider
    @State private var apiToken = ""
    @State private var accessKeyID = ""
    @State private var accessKeySecret = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: FocusedField?

    private var title: String {
        credential == nil ? "Add DNS Credential" : "Edit DNS Credential"
    }

    private var primaryActionTitle: String {
        credential == nil ? "Add" : "Save"
    }

    init(
        gateway: GatewayRuntimeController,
        credential: GatewayDNSCredentialDescriptor?
    ) {
        self.gateway = gateway
        self.credential = credential
        _label = State(initialValue: credential?.label ?? "")
        _provider = State(initialValue: credential?.provider ?? .cloudflare)
    }

    private var canSave: Bool {
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return switch provider {
        case .cloudflare: !apiToken.isEmpty
        case .aliyun: !accessKeyID.isEmpty && !accessKeySecret.isEmpty
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                PublishedServiceSheetHeader(
                    title: title,
                    subtitle: "Stored securely in Keychain"
                )

                VStack(alignment: .leading, spacing: 14) {
                    PublishedServiceFormRow("Name", systemImage: "tag") {
                        TextField("Credential name", text: $label)
                            .labelsHidden()
                            .textFieldStyle(.glassField)
                            .frame(width: 280)
                            .focused($focusedField, equals: .name)
                            .onSubmit(advanceFromName)
                    }

                    PublishedServiceFormRow("Provider", systemImage: "building.2") {
                        if credential == nil {
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
                            .help("Choose the DNS provider for certificate validation.")
                        } else {
                            Text(provider.displayName)
                                .foregroundStyle(.secondary)
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
                        PublishedServiceFormRow(
                            "AccessKey ID",
                            systemImage: "person.text.rectangle"
                        ) {
                            TextField("Required", text: $accessKeyID)
                                .labelsHidden()
                                .textFieldStyle(.glassField)
                                .frame(width: 280)
                                .focused($focusedField, equals: .accessKeyID)
                                .onSubmit {
                                    focusedField = .accessKeySecret
                                }
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
            focusedField = .name
        }
    }

    private func advanceFromName() {
        focusedField = switch provider {
        case .cloudflare: .apiToken
        case .aliyun: .accessKeyID
        }
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
            let descriptor = GatewayDNSCredentialDescriptor(
                id: credential?.id ?? UUID().uuidString.lowercased(),
                provider: provider,
                label: label.trimmingCharacters(in: .whitespacesAndNewlines),
                revision: credential?.revision ?? 1
            )
            let secret: GatewayCredentialSecret = switch provider {
            case .cloudflare:
                .cloudflare(apiToken: apiToken)
            case .aliyun:
                .aliyun(accessKeyID: accessKeyID, accessKeySecret: accessKeySecret)
            }
            do {
                try await gateway.saveDNSCredential(descriptor: descriptor, secret: secret)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
