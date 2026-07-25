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
    @Binding var isOn: Bool

    init(_ title: LocalizedStringKey, isOn: Binding<Bool>) {
        self.title = title
        _isOn = isOn
    }

    var body: some View {
        Toggle(title, isOn: $isOn)
            .toggleStyle(.switch)
            .controlSize(.small)
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
