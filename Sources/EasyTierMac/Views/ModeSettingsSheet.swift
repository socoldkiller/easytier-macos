import EasyTierShared
import SwiftUI

struct ModeSettingsSheet: View {
    enum ModeKind: String, CaseIterable, Identifiable {
        case normal = "Normal"
        case remote = "Remote"
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var kind: ModeKind
    @State private var rpcPortal: String
    @State private var rpcListenEnabled: Bool
    @State private var rpcListenPort: Int
    @State private var configServerURL: String
    @State private var remoteRPCAddress: String

    var onSave: (AppMode) -> Void

    init(mode: AppMode, onSave: @escaping (AppMode) -> Void) {
        self.onSave = onSave
        switch mode {
        case let .normal(rpcPortal, rpcListenEnabled, rpcListenPort, configServerURL):
            _kind = State(initialValue: .normal)
            _rpcPortal = State(initialValue: rpcPortal ?? "")
            _rpcListenEnabled = State(initialValue: rpcListenEnabled)
            _rpcListenPort = State(initialValue: rpcListenPort)
            _configServerURL = State(initialValue: configServerURL?.absoluteString ?? "")
            _remoteRPCAddress = State(initialValue: "tcp://127.0.0.1:15999")
        case let .remote(remoteRPCAddress):
            _kind = State(initialValue: .remote)
            _rpcPortal = State(initialValue: "")
            _rpcListenEnabled = State(initialValue: false)
            _rpcListenPort = State(initialValue: 15_999)
            _configServerURL = State(initialValue: "")
            _remoteRPCAddress = State(initialValue: remoteRPCAddress)
        case let .service(_, _, _, _, configServerURL):
            _kind = State(initialValue: .normal)
            _rpcPortal = State(initialValue: "")
            _rpcListenEnabled = State(initialValue: false)
            _rpcListenPort = State(initialValue: 15_999)
            _configServerURL = State(initialValue: configServerURL?.absoluteString ?? "")
            _remoteRPCAddress = State(initialValue: "tcp://127.0.0.1:15999")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Mode Settings")
                .font(.title2.weight(.semibold))

            Picker("Mode", selection: $kind) {
                ForEach(ModeKind.allCases) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            Form {
                switch kind {
                case .normal:
                    Toggle("Enable TCP RPC listen", isOn: $rpcListenEnabled)
                    TextField("RPC portal", text: $rpcPortal)
                        .disabled(!rpcListenEnabled)
                    Stepper("RPC listen port: \(rpcListenPort)", value: $rpcListenPort, in: 1...65_535)
                        .disabled(!rpcListenEnabled)
                    TextField("Config server URL", text: $configServerURL)
                case .remote:
                    TextField("Remote RPC address", text: $remoteRPCAddress)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    onSave(buildMode())
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520, height: 460)
    }

    private func buildMode() -> AppMode {
        switch kind {
        case .normal:
            .normal(
                rpcPortal: rpcListenEnabled ? "tcp://0.0.0.0:\(rpcListenPort)" : nil,
                rpcListenEnabled: rpcListenEnabled,
                rpcListenPort: rpcListenPort,
                configServerURL: URL(string: configServerURL.trimmingCharacters(in: .whitespacesAndNewlines))
            )
        case .remote:
            .remote(remoteRPCAddress: remoteRPCAddress.isEmpty ? "tcp://127.0.0.1:15999" : remoteRPCAddress)
        }
    }
}
