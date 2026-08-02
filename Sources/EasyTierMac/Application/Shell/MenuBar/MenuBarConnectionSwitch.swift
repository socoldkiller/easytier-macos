import EasyTierShared
import SwiftUI

struct MenuBarConnectionSwitch: View {
    var phase: RuntimeReadinessPhase
    var isDisabled: Bool
    var toggleConnection: () -> Void

    var body: some View {
        Toggle(
            accessibilityLabel,
            isOn: Binding(
                get: { isOn },
                set: { requestedValue in
                    guard requestedValue != isOn else { return }
                    toggleConnection()
                }
            )
        )
        .labelsHidden()
        .toggleStyle(.switch)
        .disabled(isDisabled)
    }

    private var isOn: Bool {
        switch phase {
        case .stopped: false
        case .starting, .ready, .failed: true
        }
    }

    private var accessibilityLabel: String {
        switch phase {
        case .stopped: "Connect"
        case .starting: "Stop Connecting"
        case .ready: "Disconnect"
        case .failed: "Stop Network"
        }
    }
}
