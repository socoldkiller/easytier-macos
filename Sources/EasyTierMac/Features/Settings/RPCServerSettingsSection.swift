import SwiftUI

struct RPCServerSettingsSection: View {
    @Binding var isEnabled: Bool
    @Binding var port: Int
    @Binding var whitelist: [String]
    let commit: () -> Void

    @FocusState private var isPortFocused: Bool

    var body: some View {
        Section {
            SettingsSwitch("Allow TCP RPC Connections", isOn: $isEnabled)

            if isEnabled {
                LabeledContent("Address") {
                    Text(verbatim: "tcp://0.0.0.0:\(port)")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                LabeledContent("Port") {
                    HStack {
                        TextField("Port", text: integerText($port))
                            .labelsHidden()
                            .font(.body.monospacedDigit())
                            .frame(width: 96)
                            .focused($isPortFocused)
                            .onSubmit(finishEditingPort)

                        Stepper("Port", value: portStepperBinding, in: 1...65_535)
                            .labelsHidden()
                    }
                }

                RPCPortalWhitelistEditor(values: $whitelist, onCommit: commit)
            }
        } header: {
            Text("RPC Server")
        } footer: {
            Text("Enable this only when trusted EasyTier clients need remote access to this Mac's control plane.")
        }
        .onChange(of: isPortFocused) { wasFocused, isFocused in
            if wasFocused, !isFocused {
                commit()
            }
        }
    }

    private var portStepperBinding: Binding<Int> {
        Binding(
            get: { port },
            set: { newValue in
                port = newValue
                commit()
            }
        )
    }

    private func finishEditingPort() {
        isPortFocused = false
    }

    private func integerText(_ value: Binding<Int>) -> Binding<String> {
        Binding(
            get: { String(value.wrappedValue) },
            set: { newValue in
                let digits = newValue.filter(\.isNumber)
                guard let intValue = Int(digits) else { return }
                value.wrappedValue = min(max(intValue, 1), 65_535)
            }
        )
    }
}
