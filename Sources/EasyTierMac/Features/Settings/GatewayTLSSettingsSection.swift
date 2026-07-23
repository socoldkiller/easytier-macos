import EasyTierShared
import SwiftUI

struct GatewayTLSSettingsSection: View {
    let gateway: GatewayRuntimeController

    @State private var contactEmail = ""
    @State private var savedContactEmail: String?
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var configurationID: String {
        gateway.acmeConfiguration?.contactEmail ?? ""
    }

    private var normalizedContactEmail: String? {
        try? GatewayPublishedServicesValidator.normalizeContactEmail(contactEmail)
    }

    private var hasUnsavedChanges: Bool {
        normalizedContactEmail != savedContactEmail
    }

    private var contactEmailIsInvalid: Bool {
        !contactEmail.isEmpty && normalizedContactEmail == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let errorMessage {
                ErrorBanner(message: errorMessage)
            }

            CardSection(
                "Certificate Contact",
                systemImage: "envelope",
                footer: "This global address is shared by all certificates. Certificate authorities use it for account, security, and renewal notices."
            ) {
                SettingsInlineRow("Contact Email") {
                    VStack(alignment: .trailing, spacing: 4) {
                        TextField("name@example.com", text: $contactEmail)
                            .textFieldStyle(.glassField)
                            .frame(maxWidth: 320)
                            .disabled(isSaving)
                        if contactEmailIsInvalid {
                            Text("Enter a valid email address.")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
                SettingsRowDivider()
                HStack {
                    Spacer(minLength: 0)
                    Button("Save", systemImage: "checkmark", action: save)
                        .buttonStyle(.borderedProminent)
                        .disabled(isSaving || !hasUnsavedChanges || normalizedContactEmail == nil)
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
    }

    private func save() {
        Task {
            isSaving = true
            errorMessage = nil
            defer { isSaving = false }
            do {
                guard let normalizedContactEmail else {
                    throw GatewayConfigurationValidationError.invalid(
                        "Enter a certificate contact email."
                    )
                }
                try await gateway.configureAutomaticHTTPS(contactEmail: normalizedContactEmail)
                savedContactEmail = normalizedContactEmail
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
