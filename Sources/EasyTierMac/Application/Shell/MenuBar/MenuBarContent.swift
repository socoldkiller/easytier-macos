import AppKit
import EasyTierShared
import Foundation
import SwiftUI

struct MenuBarContent: View {
    @Environment(AppContext.self) private var appContext
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var openMainWindowAction: (() -> Void)?
    var quitApplicationAction: () -> Void
    var dismissMenuBarAction: (() -> Void)?

    @State private var copiedDeviceAddress = false
    @State private var copyFeedbackToken = 0
    @State private var isConnectionSwitchHovering = false

    private var store: EasyTierAppStore { appContext.workspace.store }
    private var appearanceSettings: AppAppearanceSettings { appContext.settings.appearance }
    private var updater: SoftwareUpdateController { appContext.softwareUpdate.controller }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("EasyTier")
                        .font(.body.weight(.medium))
                    HStack(spacing: 6) {
                        Circle()
                            .fill(connectionIndicatorColor)
                            .frame(width: 6, height: 6)
                        Text(connectionSubtitle)
                            .font(.body)
                            .foregroundStyle(MenuBarPalette.secondaryText)
                    }
                }

                Spacer(minLength: 0)

                Button(action: toggleConnection) {
                    MenuBarConnectionSwitch(
                        phase: store.selectedRuntimeReadinessPhase,
                        isBusy: store.isBusy
                    )
                    .padding(4)
                    .background(
                        connectionSwitchBackground,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                }
                .buttonStyle(QuietPressButtonStyle(pressedScale: 0.94, pressedOpacity: 0.86))
                .disabled(store.isBusy || store.isQuitting || store.selectedConfig == nil)
                .onHover { isConnectionSwitchHovering = $0 }
                .accessibilityLabel(Text("Connection"))
                .accessibilityValue(Text(connectionSwitchAccessibilityValue))
                .accessibilityHint(Text(connectionSwitchAccessibilityHint))
                .accessibilityAddTraits(.isButton)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 10)

            MenuBarDivider()

            MenuBarNetworkRow(
                name: currentNetworkName,
                subtitle: selectedNetworkSubtitle,
                state: selectedNetworkState,
                canSwitch: canSwitchNetworks,
                open: openMainWindowAndDismiss,
                previous: selectPreviousNetwork,
                next: selectNextNetwork
            )

            MenuBarDivider()

            MenuBarCopyRow(
                title: deviceTitle,
                isCopied: copiedDeviceAddress,
                isDisabled: deviceCopyAddress == nil,
                action: copyDeviceAddress
            )
            MenuBarPlainRow(title: devicesTitle, isMuted: true)

            MenuBarDivider()

            if store.isQuitting {
                MenuBarPlainRow(title: "Quitting EasyTier...", isMuted: true)
                MenuBarDivider()
            }

            MenuBarListButton(
                title: "Check for Updates…",
                isDisabled: !updater.canCheckForUpdates || store.isQuitting,
                action: checkForUpdates
            )
            .accessibilityHint(Text("Checks for a new EasyTier version"))

            MenuBarDivider()

            MenuBarListButton(
                title: "About EasyTier",
                isDisabled: store.isQuitting,
                action: showAbout
            )
            .accessibilityHint(Text("Opens the About window"))

            MenuBarListButton(
                title: "Install on Linux",
                isDisabled: store.isQuitting,
                action: showLinuxInstallGuide
            )
            .accessibilityHint(Text("Shows instructions for installing EasyTier on a Linux server"))

            MenuBarDivider()

            MenuBarListButton(
                title: windowEffectTitle,
                isDisabled: store.isQuitting,
                action: toggleWindowEffect
            )
            .accessibilityHint(Text("Toggles frosted glass window effect"))

            MenuBarListButton(
                title: "Settings...",
                shortcut: "⌘ ,",
                isDisabled: store.isQuitting,
                action: showSettings
            )
            .accessibilityHint(Text("Opens EasyTier settings"))

            MenuBarDivider()

            MenuBarListButton(
                title: store.isQuitting ? "Quitting..." : "Quit EasyTier",
                shortcut: "⌘ Q",
                isDisabled: store.isQuitting,
                action: quit
            )
        }
        .frame(width: 292)
        .foregroundStyle(MenuBarPalette.primaryText)
        .background(
            FrostedGlass(
                role: .popover,
                renderCoordinator: appContext.presentation.glassRenderCoordinator
            )
        )
    }

    private var selectedNetworkState: ConnectionGlyphState {
        if store.lastError != nil || store.selectedRuntimeReadinessPhase == .failed { return .error }
        if store.isBusy || store.isQuitting { return .connecting }
        guard var instance = selectedRunningInstance else { return .idle }
        instance.detail = store.selectedRuntimeDetail
        return store.instanceIsFullyConnected(instance) ? .connected : .connecting
    }

    private var selectedRunningInstance: NetworkInstance? {
        guard let config = store.selectedConfig else { return nil }
        return store.runningInstance(matching: config)
    }

    private var canSwitchNetworks: Bool {
        store.configs.count > 1
    }

    private var currentNetworkName: String {
        store.selectedConfig?.network_name ?? "No network selected"
    }

    private var deviceTitle: String {
        "This Device: \(deviceName) (\(deviceAddress))"
    }

    private var deviceName: String {
        let runtimeHostname = store.selectedRuntimeDetail?.my_node_info?.hostname
        let configHostname = store.selectedConfig?.hostname
        return runtimeHostname?.nilIfEmpty
            ?? configHostname?.nilIfEmpty
            ?? Host.current().localizedName?.nilIfEmpty
            ?? "This Mac"
    }

    private var deviceAddress: String {
        let node = store.selectedRuntimeDetail?.my_node_info
        return node?.virtual_ipv4?.displayString.nilIfEmpty ?? node?.ipv4_addr?.nilIfEmpty ?? "-"
    }

    private var deviceCopyAddress: String? {
        let address = deviceAddress.split(separator: "/", maxSplits: 1).first.map(String.init) ?? deviceAddress
        return address == "-" ? nil : address
    }

    private var devicesTitle: String {
        let count = store.selectedMemberStatuses.count
        if count > 0 { return "\(count) Devices" }
        return store.selectedConfigCanStop ? "Loading Devices..." : "No Devices"
    }

    private var windowEffectTitle: String {
        "Window Effect: \(appearanceSettings.glassEffectsEnabled ? "Frosted Glass" : "Traditional")"
    }

    private var connectionSubtitle: String {
        if store.isQuitting { return "Quitting" }
        if store.isBusy { return "Working" }
        if store.lastError != nil || store.selectedRuntimeReadinessPhase == .failed { return "Needs Attention" }
        guard store.selectedConfig != nil else { return "No Network" }
        if store.selectedRuntimeReadinessPhase == .starting { return "Starting" }
        guard var instance = selectedRunningInstance else { return "Not Connected" }
        instance.detail = store.selectedRuntimeDetail
        return store.instanceIsFullyConnected(instance) ? "Connected" : "Connecting"
    }

    private var connectionIndicatorColor: Color {
        if store.isQuitting { return .yellow.opacity(0.82) }
        if store.lastError != nil || store.selectedRuntimeReadinessPhase == .failed { return .orange }
        if store.isBusy { return .yellow.opacity(0.82) }
        guard var instance = selectedRunningInstance else { return MenuBarPalette.mutedText }
        instance.detail = store.selectedRuntimeDetail
        return store.instanceIsFullyConnected(instance) ? MenuBarPalette.connected : .yellow.opacity(0.82)
    }

    private var connectionSwitchBackground: Color {
        guard isConnectionSwitchHovering,
              !store.isBusy,
              !store.isQuitting,
              store.selectedConfig != nil
        else {
            return .clear
        }
        return MenuBarPalette.selectedRow
    }

    private var selectedNetworkSubtitle: String {
        if store.selectedConfig == nil { return "Select a network" }
        if store.selectedRuntimeReadinessPhase == .failed { return "Needs Attention" }
        if store.selectedRuntimeReadinessPhase == .starting { return "Starting" }
        guard var instance = selectedRunningInstance else { return "Disconnected" }
        instance.detail = store.selectedRuntimeDetail
        return store.instanceIsFullyConnected(instance) ? "Connected" : "Connecting"
    }

    private var connectionSwitchAccessibilityValue: String {
        if store.isBusy { return "Working" }
        return switch store.selectedRuntimeReadinessPhase {
        case .stopped: "Off"
        case .starting: "Starting"
        case .ready: "On"
        case .failed: "Needs Attention"
        }
    }

    private var connectionSwitchAccessibilityHint: String {
        store.selectedConfigCanStop
            ? "Stops the selected network"
            : "Starts the selected network"
    }

    private func openMainWindow() {
        if let openMainWindowAction {
            openMainWindowAction()
            return
        }

        NSApplication.shared.unhide(nil)
        openWindow(id: EasyTierWindowID.main)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func openMainWindowAndDismiss() {
        dismissMenuBar()
        openMainWindow()
    }

    private func dismissMenuBar() {
        dismissMenuBarAction?()
        dismiss()
    }

    private func toggleConnection() {
        Task {
            await store.toggleSelectedConfigConnection()
        }
    }

    private func selectPreviousNetwork() {
        store.selectPreviousConfig()
    }

    private func selectNextNetwork() {
        store.selectNextConfig()
    }

    private func copyDeviceAddress() {
        guard let address = deviceCopyAddress else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)

        copyFeedbackToken += 1
        let token = copyFeedbackToken
        copiedDeviceAddress = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_200))
            if copyFeedbackToken == token {
                copiedDeviceAddress = false
            }
        }
    }

    private func checkForUpdates() {
        dismissMenuBar()
        updater.checkForUpdates()
    }

    private func showAbout() {
        openMainWindow()
        store.isShowingAbout = true
        dismissMenuBar()
    }

    private func showLinuxInstallGuide() {
        openMainWindow()
        store.isShowingLinuxInstallGuide = true
        dismissMenuBar()
    }

    private func toggleWindowEffect() {
        appearanceSettings.glassEffectsEnabled.toggle()
    }

    private func showSettings() {
        openMainWindow()
        store.isShowingSettings = true
        dismissMenuBar()
    }

    private func quit() {
        dismissMenuBar()
        quitApplicationAction()
    }
}
