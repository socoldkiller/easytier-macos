import AppKit
import EasyTierShared
import Foundation
import SwiftUI

struct MenuBarContent: View {
    @Environment(AppContext.self) private var appContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var openMainWindowAction: (() -> Void)?
    var quitApplicationAction: () -> Void
    var dismissMenuBarAction: (() -> Void)?
    var presentationState: MenuBarPresentationState
    var networkMenuAnchorAvailabilityDidChange: @MainActor @Sendable (NSView, Bool) -> Void
    var networkMenuPresentationDidChange: (Bool) -> Void
    var networkMenuTriggerHoverDidChange: (Bool) -> Void
    var preferredSizeDidChange: (NSSize) -> Void

    @State private var copiedDeviceAddress = false
    @State private var copyFeedbackToken = 0

    private var store: EasyTierAppStore { appContext.workspace.store }
    private var appearanceSettings: AppAppearanceSettings { appContext.settings.appearance }
    private var updater: SoftwareUpdateController { appContext.softwareUpdate.controller }
    private var networkItems: [NetworkPresentationItem] { NetworkPresentationResolver.items(for: store) }
    private var networkSummary: NetworkCollectionSummary { NetworkCollectionSummary(items: networkItems) }
    private var currentNetwork: NetworkPresentationItem? {
        networkItems.first(where: \.isSelected) ?? networkItems.first
    }
    private var account: StoredRemoteAccount? {
        guard store.configurationAuthority == .configServer else { return nil }
        return appContext.settings.account?.activeAccount
    }

    var body: some View {
        primaryMenu
            .frame(width: Self.primaryWidth, height: Self.preferredHeight)
            .foregroundStyle(MenuBarPalette.primaryText)
            .background(menuBackgroundTint)
            .onAppear(perform: reportPreferredSize)
            .onChange(of: networkItems.count) { _, count in
                if count == 0 { setNetworkMenuPresented(false) }
            }
    }

    private var primaryMenu: some View {
        VStack(spacing: 0) {
            MenuBarAggregateHeader(summary: networkSummary, isQuitting: store.isQuitting)

            if let account {
                MenuBarAccountHeader(
                    account: account,
                    phase: appContext.settings.account?.phase ?? .signedOut,
                    isNetworkMenuPresented: presentationState.isNetworkMenuPresented,
                    canPresentNetworkMenu: !networkItems.isEmpty,
                    presentNetworkMenu: presentNetworkMenu,
                    hoverDidChange: networkMenuTriggerHoverDidChange,
                    toggleNetworkMenu: toggleNetworkMenu
                )
                .background {
                    MenuBarNetworkMenuAnchor(
                        availabilityDidChange: networkMenuAnchorAvailabilityDidChange
                    )
                }
            } else {
                MenuBarCurrentNetworkRow(
                    network: currentNetwork,
                    showsNetworkMenuDisclosure: true,
                    isNetworkMenuPresented: presentationState.isNetworkMenuPresented,
                    controlsAreDisabled: controlsAreDisabled,
                    open: openMainWindowAndDismiss,
                    presentNetworkMenu: presentNetworkMenu,
                    hoverDidChange: networkMenuTriggerHoverDidChange,
                    toggleNetworkMenu: toggleNetworkMenu,
                    toggleConnection: toggleCurrentNetwork
                )
                .background {
                    MenuBarNetworkMenuAnchor(
                        availabilityDidChange: networkMenuAnchorAvailabilityDidChange
                    )
                }
            }

            MenuBarDivider()

            MenuBarCopyRow(
                title: deviceTitle,
                isCopied: copiedDeviceAddress,
                isDisabled: deviceCopyAddress == nil,
                action: copyDeviceAddress
            )
            MenuBarPlainRow(title: devicesTitle, isMuted: true)

            MenuBarDivider()

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
    }

    private static let primaryWidth: CGFloat = 300
    private static let preferredHeight: CGFloat = 340

    private var controlsAreDisabled: Bool {
        !store.persistenceIsReady || store.isBusy || store.isQuitting
    }

    private var menuBackgroundTint: Color {
        Color(nsColor: .windowBackgroundColor)
            .opacity(colorScheme == .dark ? 0.58 : 0.68)
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

    private func reportPreferredSize() {
        preferredSizeDidChange(NSSize(width: Self.primaryWidth, height: Self.preferredHeight))
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

    private func toggleNetworkMenu() {
        guard !networkItems.isEmpty else { return }
        setNetworkMenuPresented(!presentationState.isNetworkMenuPresented)
    }

    private func presentNetworkMenu() {
        guard !networkItems.isEmpty else { return }
        setNetworkMenuPresented(true)
    }

    private func setNetworkMenuPresented(_ presented: Bool) {
        guard presentationState.isNetworkMenuPresented != presented else { return }
        withAnimation(EasyTierMotion.content(reduceMotion: reduceMotion)) {
            presentationState.isNetworkMenuPresented = presented
        }
        networkMenuPresentationDidChange(presented)
    }

    private func toggleCurrentNetwork() {
        guard let currentNetwork else { return }
        toggleNetworkConnection(currentNetwork.id)
    }

    private func toggleNetworkConnection(_ id: String) {
        Task { await store.toggleConfigConnection(id: id) }
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
            if copyFeedbackToken == token { copiedDeviceAddress = false }
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

private struct MenuBarAggregateHeader: View {
    let summary: NetworkCollectionSummary
    let isQuitting: Bool

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("EasyTier")
                    .font(.body.weight(.medium))
                HStack(spacing: 5) {
                    Circle()
                        .fill(indicatorColor)
                        .frame(width: 5, height: 5)
                    Text(isQuitting ? "Quitting" : summary.displayText)
                        .font(.callout)
                        .foregroundStyle(MenuBarPalette.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var indicatorColor: Color {
        if isQuitting { return .yellow.opacity(0.82) }
        return switch summary.connectionState {
        case .idle: MenuBarPalette.mutedText
        case .connecting: .yellow.opacity(0.82)
        case .connected: MenuBarPalette.connected
        case .error: .orange
        }
    }
}

private struct MenuBarAccountHeader: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let account: StoredRemoteAccount
    let phase: AccountSettingsModel.Phase
    let isNetworkMenuPresented: Bool
    let canPresentNetworkMenu: Bool
    let presentNetworkMenu: () -> Void
    let hoverDidChange: (Bool) -> Void
    let toggleNetworkMenu: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: toggleNetworkMenu) {
            HStack(spacing: 9) {
                AccountAvatarView(size: 30, showsStatus: true, isConnected: phase == .connected)
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.profile.username)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(primaryTextColor)
                        .lineLimit(1)
                    Text(account.profile.controlOrigin.host() ?? account.profile.controlOrigin.absoluteString)
                        .font(.caption)
                        .foregroundStyle(secondaryTextColor)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(secondaryTextColor)
                    .lineLimit(1)
                if canPresentNetworkMenu {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(secondaryTextColor)
                        .frame(width: 12)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(rowBackground, in: .rect(cornerRadius: MenuBarPalette.selectedRowCornerRadius))
            .padding(.horizontal, MenuBarPalette.selectedRowHorizontalInset)
            .padding(.vertical, MenuBarPalette.selectedRowVerticalInset)
        }
        .buttonStyle(QuietPressButtonStyle(pressedScale: 0.985, pressedOpacity: 0.82))
        .disabled(!canPresentNetworkMenu)
        .onHover { hovering in
            isHovering = hovering
            hoverDidChange(hovering)
            if hovering { presentNetworkMenu() }
        }
        .animation(EasyTierMotion.quick(reduceMotion: reduceMotion), value: isActive)
        .accessibilityLabel("Networks for \(account.profile.username)")
        .accessibilityHint(isNetworkMenuPresented ? "Hides the network list" : "Shows the network list")
    }

    private var isActive: Bool {
        canPresentNetworkMenu && (isHovering || isNetworkMenuPresented)
    }

    private var primaryTextColor: Color {
        isActive ? MenuBarPalette.selectedRowText : MenuBarPalette.primaryText
    }

    private var secondaryTextColor: Color {
        isActive ? MenuBarPalette.selectedRowText.opacity(0.82) : MenuBarPalette.secondaryText
    }

    private var rowBackground: Color {
        isActive ? MenuBarPalette.selectedRow : .clear
    }

    private var statusText: String {
        switch phase {
        case .connected: "Connected"
        case .retrying: "Reconnecting"
        case .waitingForBrowser: "Signing In"
        case .connecting: "Connecting"
        case .signedOut: "Signed Out"
        case .failed: "Issue"
        }
    }
}
