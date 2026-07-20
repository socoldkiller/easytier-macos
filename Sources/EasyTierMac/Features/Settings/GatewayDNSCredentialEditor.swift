import EasyTierShared
import SwiftUI

struct GatewayDNSCredentialEditor: View {
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
        VStack(alignment: .leading, spacing: 18) {
            Text(credential == nil ? "Add DNS Credential" : "Edit DNS Credential")
                .font(.title3)
                .bold()

            if let errorMessage {
                ErrorBanner(message: errorMessage)
            }

            Form {
                TextField("Name", text: $label)
                Picker("DNS Provider", selection: $provider) {
                    ForEach([GatewayDNSProvider.cloudflare, .aliyun], id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .disabled(credential != nil)

                switch provider {
                case .cloudflare:
                    SecureField("API Token", text: $apiToken)
                case .aliyun:
                    TextField("AccessKey ID", text: $accessKeyID)
                    SecureField("AccessKey Secret", text: $accessKeySecret)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel) { dismiss() }
                    .disabled(isWorking)
                Button("Save", systemImage: "checkmark", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking || !canSave)
            }
        }
        .padding(22)
        .frame(width: 440)
        .task(loadSecret)
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
