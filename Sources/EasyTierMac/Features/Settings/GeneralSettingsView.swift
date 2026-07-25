import EasyTierShared
import SwiftUI

struct GeneralSettingsView: View {
    @Environment(AppContext.self) private var appContext
    @Environment(\.accessibilityShowButtonShapes) private var showButtonShapes

    private let appInfo = AppVersionInfo.current

    private var store: EasyTierAppStore { appContext.workspace.store }
    private var appearance: AppAppearanceSettings { appContext.settings.appearance }
    private var updater: SoftwareUpdateController { appContext.softwareUpdate.controller }
    private var loginItem: LoginItemController { appContext.settings.loginItem }

    var body: some View {
        SettingsForm {
            Section {
                SettingsSwitch(
                    "Use Frosted Glass",
                    isOn: appearance.glassEffectsEnabledBinding,
                    showsBetaBadge: true
                )
                SettingsSwitch("Show EasyTier in Dock", isOn: appearance.showsDockIconBinding)
            } header: {
                Text("Appearance")
            } footer: {
                Text("Frosted Glass is an optional preview appearance. EasyTier always respects Reduce Transparency.")
            }

            Section {
                SettingsSwitch("Launch at Login", isOn: loginItemBinding)
                    .onChange(of: loginItem.isEnabled) { _, _ in
                        loginItem.apply()
                    }
                SettingsSwitch("Keep Networks Running After Quit", isOn: vpnOnDemandBinding)
                    .disabled(!store.persistenceIsReady)
            } header: {
                Text("Startup & Background")
            } footer: {
                Text("Helper-managed networks can continue running after the EasyTier app quits.")
            }

            Section {
                SettingsSwitch("Check for Updates Automatically", isOn: autoCheckUpdatesBinding)
                LabeledContent("Update Channel") {
                    Picker("Update Channel", selection: updateTrackBinding) {
                        ForEach(SoftwareUpdateTrack.allCases) { track in
                            Text(track.displayName).tag(track)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.regular)
                    .font(.body)
                    .frame(width: 120, alignment: .trailing)
                    .background(
                        Color.primary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(
                                .primary.opacity(showButtonShapes ? 0.35 : 0.1),
                                lineWidth: showButtonShapes ? 1 : 0.5
                            )
                    }
                    .disabled(updater.sessionInProgress)
                }
                LabeledContent("Updates") {
                    Button("Check for Updates…", action: checkForUpdates)
                        .disabled(!updater.canCheckForUpdates)
                }
            } header: {
                Text("Software Update")
            } footer: {
                Text(softwareUpdateFooterText)
            }
        }
        .task {
            await Task.yield()
            loginItem.refresh()
        }
    }

    private var loginItemBinding: Binding<Bool> {
        Binding(
            get: { loginItem.isEnabled },
            set: { loginItem.isEnabled = $0 }
        )
    }

    private var vpnOnDemandBinding: Binding<Bool> {
        Binding(
            get: { store.vpnOnDemandEnabled },
            set: { enabled in
                Task { await store.setVPNOnDemandEnabled(enabled) }
            }
        )
    }

    private var autoCheckUpdatesBinding: Binding<Bool> {
        Binding(
            get: { updater.automaticallyChecksForUpdates },
            set: { updater.automaticallyChecksForUpdates = $0 }
        )
    }

    private var updateTrackBinding: Binding<SoftwareUpdateTrack> {
        Binding(
            get: { updater.updateTrack },
            set: { updater.updateTrack = $0 }
        )
    }

    private var softwareUpdateFooterText: String {
        if updater.updateTrack == .nightly {
            return "Built nightly from the latest EasyTier GUI and Core. Nightly builds may be unstable."
        }
        if appInfo.buildChannel == .nightly {
            return "Stable updates are selected. This Nightly build remains installed until a newer Stable release is available."
        }
        return "EasyTier checks signed Stable releases at most once every 24 hours."
    }

    private func checkForUpdates() {
        updater.checkForUpdates()
    }
}
