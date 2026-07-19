import EasyTierShared
import SwiftUI

struct EditPublishedServiceSheet: View {
    @Environment(\.dismiss) private var dismiss

    let service: GatewayPublishedService
    let onSave: (Int) -> Void

    @State private var portText: String
    @FocusState private var portFocused: Bool

    private var parsedPort: Int? {
        guard let port = Int(portText), (1 ... 65_535).contains(port) else { return nil }
        return port
    }

    private var canSave: Bool {
        parsedPort != nil && parsedPort != service.targetPort
    }

    init(service: GatewayPublishedService, onSave: @escaping (Int) -> Void) {
        self.service = service
        self.onSave = onSave
        _portText = State(initialValue: String(service.targetPort))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Edit Service")
                    .font(.title3)
                    .bold()
                Text(service.publicHostname)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            SettingsCard {
                SettingsInlineRow("Target") {
                    Text(service.targetDomain)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                SettingsRowDivider()
                SettingsInlineRow("Port") {
                    TextField("Port", text: $portText)
                        .textFieldStyle(.glassField)
                        .font(.body.monospacedDigit())
                        .frame(width: 120)
                        .focused($portFocused)
                        .onSubmit(save)
                }
            }

            HStack {
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save", systemImage: "checkmark", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 420)
        .task {
            portFocused = true
        }
    }

    private func save() {
        guard let parsedPort, canSave else { return }
        onSave(parsedPort)
        dismiss()
    }
}
