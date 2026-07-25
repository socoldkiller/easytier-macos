import EasyTierShared
import SwiftUI

struct GatewayTLSSettingsSection: View {
    let gateway: GatewayRuntimeController

    @State private var contactEmail = ""
    @State private var savedContactEmail: String?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var hasAttemptedCommit = false
    @FocusState private var contactEmailIsFocused: Bool

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
        normalizedContactEmail == nil
            && (!contactEmail.isEmpty || (hasAttemptedCommit && hasUnsavedChanges))
    }

    var body: some View {
        Section {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }

            LabeledContent("Contact Email") {
                HStack(alignment: .top, spacing: 6) {
                    VStack(alignment: .trailing, spacing: 4) {
                        TextField("name@example.com", text: $contactEmail)
                            .labelsHidden()
                            .frame(width: 240)
                            .focused($contactEmailIsFocused)
                            .onSubmit(saveIfNeeded)
                            .disabled(isSaving)
                        if contactEmailIsInvalid {
                            Text("Enter a valid email address.")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Saving contact email")
                    }
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
        .onChange(of: contactEmailIsFocused) { wasFocused, isFocused in
            if wasFocused, !isFocused {
                saveIfNeeded()
            }
        }
        .onChange(of: contactEmail) { _, _ in
            errorMessage = nil
        }
    }

    private func synchronizeFromGateway() {
        let configuration = gateway.acmeConfiguration
        contactEmail = configuration?.contactEmail ?? ""
        savedContactEmail = configuration?.contactEmail
        hasAttemptedCommit = false
    }

    private func saveIfNeeded() {
        guard hasUnsavedChanges, !isSaving else { return }
        hasAttemptedCommit = true
        guard normalizedContactEmail != nil else { return }
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
                hasAttemptedCommit = false
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
