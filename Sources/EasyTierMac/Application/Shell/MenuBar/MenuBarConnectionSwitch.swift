import EasyTierShared
import SwiftUI

struct MenuBarConnectionSwitch: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var phase: RuntimeReadinessPhase
    var isBusy: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(trackColor)
                .overlay {
                    Capsule()
                        .stroke(MenuBarPalette.divider, lineWidth: 0.6)
                }

            Circle()
                .fill(knobColor)
                .overlay {
                    Circle()
                        .stroke(Color.black.opacity(0.16), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.16), radius: 1, x: 0, y: 1)
                .padding(2)
        }
        .frame(width: 36, height: 20)
        .opacity(isBusy ? 0.58 : 1)
        .animation(EasyTierMotion.selection(reduceMotion: reduceMotion), value: phase)
        .accessibilityLabel(Text(accessibilityLabel))
    }

    private var isOn: Bool {
        phase == .ready
    }

    private var trackColor: Color {
        switch phase {
        case .stopped: MenuBarPalette.rowHighlight
        case .starting: Color.yellow.opacity(0.42)
        case .ready: MenuBarPalette.connected.opacity(0.82)
        case .failed: Color.orange.opacity(0.46)
        }
    }

    private var knobColor: Color {
        Color.white.opacity(0.92)
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
