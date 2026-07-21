import SwiftUI

struct GatewayTLSSettingsSection: View {
    let gateway: GatewayRuntimeController

    @State private var contactEmail = ""
    @State private var savedContactEmail: String?
    @State private var termsOfServiceAgreed = false
    @State private var savedTermsOfServiceAgreed = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var configurationID: String {
        let configuration = gateway.acmeConfiguration
        return "\(configuration?.contactEmail ?? "")-\(configuration?.termsOfServiceAgreed == true)"
    }

    private var normalizedContactEmail: String? {
        let email = contactEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        return email.isEmpty ? nil : email
    }

    private var hasUnsavedChanges: Bool {
        normalizedContactEmail != savedContactEmail
            || termsOfServiceAgreed != savedTermsOfServiceAgreed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let errorMessage {
                ErrorBanner(message: errorMessage)
            }

            CardSection(
                "Managed Certificate",
                systemImage: "lock.shield",
                footer: "Choose Let's Encrypt or ZeroSSL and a validation method for each Published Service."
            ) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Managed HTTPS")
                            .bold()
                        Text("Certificate authority and validation are selected per service")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    StatusPill(
                        gateway.isTLSConfigured ? "Ready" : "Setup Required",
                        tone: gateway.isTLSConfigured ? .positive : .warning
                    )
                }
                SettingsRowDivider()
                SettingsInlineRow("Contact Email") {
                    TextField("Required for published services", text: $contactEmail)
                        .textFieldStyle(.glassField)
                        .frame(maxWidth: 320)
                        .disabled(isSaving)
                }
                SettingsRowDivider()
                Toggle(isOn: $termsOfServiceAgreed) {
                    Text("Enable managed certificates and accept the selected authorities' terms")
                }
                .disabled(isSaving)
                SettingsRowDivider()
                HStack {
                    Spacer(minLength: 0)
                    Button("Save", systemImage: "checkmark", action: save)
                        .buttonStyle(.borderedProminent)
                        .disabled(isSaving || !hasUnsavedChanges)
                }
            }
        }
        .task(id: configurationID) {
            synchronizeFromGateway()
        }
    }

    private func synchronizeFromGateway() {
        let configuration = gateway.acmeConfiguration
        contactEmail = configuration?.contactEmail ?? ""
        savedContactEmail = configuration?.contactEmail
        termsOfServiceAgreed = configuration?.termsOfServiceAgreed ?? false
        savedTermsOfServiceAgreed = configuration?.termsOfServiceAgreed ?? false
    }

    private func save() {
        Task {
            isSaving = true
            errorMessage = nil
            defer { isSaving = false }
            do {
                try await gateway.configureACME(
                    contactEmail: normalizedContactEmail,
                    termsOfServiceAgreed: termsOfServiceAgreed
                )
                savedContactEmail = normalizedContactEmail
                savedTermsOfServiceAgreed = termsOfServiceAgreed
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
