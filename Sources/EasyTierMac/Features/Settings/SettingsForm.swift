import SwiftUI

struct SettingsForm<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        Form {
            content
        }
        .formStyle(.grouped)
        .textFieldStyle(.glassField)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden, axes: .vertical)
        .hideScrollViewScrollers()
    }
}

struct SettingsSwitch: View {
    let title: LocalizedStringKey
    let showsBetaBadge: Bool
    @Binding var isOn: Bool

    init(
        _ title: LocalizedStringKey,
        isOn: Binding<Bool>,
        showsBetaBadge: Bool = false
    ) {
        self.title = title
        self.showsBetaBadge = showsBetaBadge
        _isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 6) {
                Text(title)
                if showsBetaBadge {
                    BetaBadge()
                }
            }
        }
            .toggleStyle(.switch)
            .controlSize(.small)
    }
}

struct BetaBadge: View {
    var body: some View {
        Text("Beta")
            .font(.caption2)
            .bold()
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.orange.opacity(0.12), in: .capsule)
            .accessibilityLabel("Beta feature")
    }
}

extension AppAppearanceSettings {
    var glassEffectsEnabledBinding: Binding<Bool> {
        Binding(
            get: { self.glassEffectsEnabled },
            set: { self.glassEffectsEnabled = $0 }
        )
    }

    var glassPanelBackgroundsEnabledBinding: Binding<Bool> {
        Binding(
            get: { self.glassPanelBackgroundsEnabled },
            set: { self.glassPanelBackgroundsEnabled = $0 }
        )
    }

    var showsDockIconBinding: Binding<Bool> {
        Binding(
            get: { self.showsDockIcon },
            set: { self.showsDockIcon = $0 }
        )
    }
}
