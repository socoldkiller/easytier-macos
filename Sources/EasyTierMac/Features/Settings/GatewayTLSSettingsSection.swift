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
        Section {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }

            LabeledContent("Contact Email") {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .trailing, spacing: 4) {
                        TextField("name@example.com", text: $contactEmail)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 240)
                            .disabled(isSaving)
                        if contactEmailIsInvalid {
                            Text("Enter a valid email address.")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    Button("Save", action: save)
                        .controlSize(.small)
                        .disabled(isSaving || !hasUnsavedChanges || normalizedContactEmail == nil)
                }
            }
        } header: {
            Text("Automatic HTTPS")
        } footer: {
            Text("Certificate authorities use this address for account, security, and renewal notices.")
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
