import EasyTierShared
import AppKit
import Foundation
import SwiftUI

struct MenuBarContent: View {
    @Environment(EasyTierAppStore.self) private var store
    @Environment(AppAppearanceSettings.self) private var appearanceSettings
    @Environment(SoftwareUpdateController.self) private var updater
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var openMainWindowAction: (() -> Void)?
    var dismissMenuBarAction: (() -> Void)?

    @State private var copiedDeviceAddress = false
    @State private var copyFeedbackToken = 0
    @State private var isConnectionSwitchHovering = false

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
                    MenuBarConnectionSwitch(phase: store.selectedRuntimeReadinessPhase, isBusy: store.isBusy)
                        .padding(4)
                        .background(connectionSwitchBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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

            MenuBarCopyRow(title: deviceTitle, isCopied: copiedDeviceAddress, isDisabled: deviceCopyAddress == nil) {
                copyDeviceAddress()
            }
            MenuBarPlainRow(title: devicesTitle, isMuted: true)

            MenuBarDivider()

            if store.isQuitting {
                MenuBarPlainRow(title: "Quitting EasyTier...", isMuted: true)
                MenuBarDivider()
            }

            if updater.hasUnacknowledgedUpdate {
                MenuBarUpdateBanner {
                    openMainWindow()
                    updater.checkForUpdatesAndPresent()
                    dismissMenuBar()
                }
                MenuBarDivider()
            }

            MenuBarListButton(title: "About EasyTier", isDisabled: store.isQuitting) {
                openMainWindow()
                store.isShowingAbout = true
                dismissMenuBar()
            }
            .accessibilityHint(Text("Opens the About window"))

            MenuBarListButton(title: "Install on Linux", isDisabled: store.isQuitting) {
                openMainWindow()
                store.isShowingLinuxInstallGuide = true
                dismissMenuBar()
            }
            .accessibilityHint(Text("Shows instructions for installing EasyTier on a Linux server"))

            MenuBarDivider()

            MenuBarListButton(title: windowEffectTitle, isDisabled: store.isQuitting) {
                appearanceSettings.glassEffectsEnabled.toggle()
            }
            .accessibilityHint(Text("Toggles frosted glass window effect"))

            MenuBarListButton(title: "Settings...", shortcut: "⌘ ,", isDisabled: store.isQuitting) {
                openMainWindow()
                store.isShowingSettings = true
                dismissMenuBar()
            }
            .accessibilityHint(Text("Opens EasyTier settings"))

            MenuBarDivider()

            MenuBarListButton(title: store.isQuitting ? "Quitting..." : "Quit EasyTier", shortcut: "⌘ Q", isDisabled: store.isQuitting) {
                dismissMenuBar()
                EasyTierApplicationDelegate.quitEasyTier()
            }
        }
        .frame(width: 292)
        .foregroundStyle(MenuBarPalette.primaryText)
        .background(MenuBarPanelBackground())
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
        guard isConnectionSwitchHovering, !store.isBusy, !store.isQuitting, store.selectedConfig != nil else { return .clear }
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
        switch store.selectedRuntimeReadinessPhase {
        case .stopped: return "Off"
        case .starting: return "Starting"
        case .ready: return "On"
        case .failed: return "Needs Attention"
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

        NSApp.unhide(nil)
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
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
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await MainActor.run {
                if copyFeedbackToken == token {
                    copiedDeviceAddress = false
                }
            }
        }
    }

}
private enum MenuBarPalette {
    static let primaryText = Color.primary
    static let secondaryText = Color.secondary
    static let mutedText = Color.secondary.opacity(0.6)
    static let divider = Color.primary.opacity(0.14)
    static let rowHighlight = Color.primary.opacity(0.08)
    static let selectedRow = EasyTierColors.menuBarSelectedRow
    static let selectedRowHorizontalInset: CGFloat = 12
    static let selectedRowVerticalInset: CGFloat = 5
    static let selectedRowContentVerticalPadding: CGFloat = 4
    static let connected = EasyTierColors.menuBarConnected
    static let selectedRowText = Color(nsColor: .selectedMenuItemTextColor)
}

private struct MenuBarPanelBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        configure(view)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        configure(view)
    }

    private func configure(_ view: NSVisualEffectView) {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        view.material = reduceTransparency ? .windowBackground : .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
    }
}

private struct MenuBarDivider: View {
    var body: some View {
        Rectangle()
            .fill(MenuBarPalette.divider)
            .frame(height: 1)
            .padding(.horizontal, 12)
    }
}

private struct MenuBarConnectionSwitch: View {
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
                .padding(2.5)
        }
        .frame(width: 40, height: 24)
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

private struct MenuBarNetworkAvatar: View {
    var state: ConnectionGlyphState

    var body: some View {
        ZStack {
            Circle()
                .fill(avatarColor)
            ConnectionGlyph(state: state, size: 20)
                .opacity(0.78)
        }
        .frame(width: 36, height: 36)
    }

    private var avatarColor: Color {
        switch state {
        case .connected: Color.primary.opacity(0.16)
        case .connecting: Color.primary.opacity(0.13)
        case .error: Color.primary.opacity(0.12)
        case .idle: Color.primary.opacity(0.09)
        }
    }
}

private struct MenuBarNetworkRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var name: String
    var subtitle: String
    var state: ConnectionGlyphState
    var canSwitch: Bool
    var open: () -> Void
    var previous: () -> Void
    var next: () -> Void

    @State private var isOpenHovering = false
    @State private var isPreviousHovering = false
    @State private var isNextHovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: open) {
                HStack(spacing: 10) {
                    MenuBarNetworkAvatar(state: state)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .font(.body.weight(.medium))
                            .foregroundStyle(primaryTextColor)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.body)
                            .foregroundStyle(secondaryTextColor)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)

                    if !canSwitch {
                        Image(systemName: "chevron.right")
                            .font(.body.weight(.medium))
                            .foregroundStyle(primaryTextColor)
                    }
                }
                .contentShape(Rectangle())
                .padding(.leading, 8)
                .padding(.trailing, canSwitch ? 0 : 8)
                .padding(.vertical, 6)
            }
            .buttonStyle(QuietPressButtonStyle(pressedScale: 0.985, pressedOpacity: 0.82))
            .frame(maxWidth: .infinity)
            .onHover { isOpenHovering = $0 }

            if canSwitch {
                HStack(spacing: 0) {
                    inlineChevronButton(
                        systemName: "chevron.left",
                        help: "Previous network",
                        isHovering: $isPreviousHovering,
                        action: previous
                    )
                    inlineChevronButton(
                        systemName: "chevron.right",
                        help: "Next network",
                        isHovering: $isNextHovering,
                        action: next
                    )
                }
                .padding(.trailing, 4)
            }
        }
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, MenuBarPalette.selectedRowHorizontalInset)
        .padding(.vertical, MenuBarPalette.selectedRowVerticalInset)
        .animation(EasyTierMotion.quick(reduceMotion: reduceMotion), value: isOpenHovering)
        .animation(EasyTierMotion.quick(reduceMotion: reduceMotion), value: isPreviousHovering)
        .animation(EasyTierMotion.quick(reduceMotion: reduceMotion), value: isNextHovering)
        .animation(EasyTierMotion.content(reduceMotion: reduceMotion), value: name)
    }

    private func inlineChevronButton(
        systemName: String,
        help: String,
        isHovering: Binding<Bool>,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body.weight(.semibold))
                .foregroundStyle(inlineChevronColor(isHovering: isHovering.wrappedValue))
                .frame(width: 24, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(QuietPressButtonStyle(pressedScale: 0.9, pressedOpacity: 0.76))
        .onHover { isHovering.wrappedValue = $0 }
        .help(help)
    }

    private var primaryTextColor: Color {
        isRowActive ? MenuBarPalette.selectedRowText : MenuBarPalette.primaryText
    }

    private var secondaryTextColor: Color {
        isRowActive ? MenuBarPalette.selectedRowText.opacity(0.82) : MenuBarPalette.secondaryText
    }

    private var rowBackground: Color {
        isRowActive ? MenuBarPalette.selectedRow : .clear
    }

    private var isRowActive: Bool {
        isOpenHovering || isPreviousHovering || isNextHovering
    }

    private func inlineChevronColor(isHovering: Bool) -> Color {
        isRowActive ? MenuBarPalette.selectedRowText.opacity(isHovering ? 1.0 : 0.92) : MenuBarPalette.primaryText
    }
}

private struct MenuBarPlainRow: View {
    var title: String
    var isMuted = false

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.body.weight(.medium))
                .foregroundStyle(isMuted ? MenuBarPalette.mutedText : MenuBarPalette.primaryText)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

private struct MenuBarCopyRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var title: String
    var isCopied: Bool
    var isDisabled: Bool
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: isCopied ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 18, height: 18)
                    .opacity(isDisabled ? 0 : 1)
                    .contentTransition(.symbolEffect(.replace))
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, MenuBarPalette.selectedRowContentVerticalPadding)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, MenuBarPalette.selectedRowHorizontalInset)
            .padding(.vertical, MenuBarPalette.selectedRowVerticalInset)
        }
        .buttonStyle(QuietPressButtonStyle(pressedScale: 0.985, pressedOpacity: 0.82))
        .disabled(isDisabled)
        .onHover { isHovering = $0 }
        .animation(EasyTierMotion.quick(reduceMotion: reduceMotion), value: isCopied)
        .animation(EasyTierMotion.quick(reduceMotion: reduceMotion), value: isHovering)
        .help("Copy IP address")
        .accessibilityHint(Text("Copies the device IP address to the clipboard"))
        .accessibilityValue(Text(isCopied ? "Copied" : ""))
    }

    private var titleColor: Color {
        if isHovering, !isDisabled { return MenuBarPalette.selectedRowText }
        return isDisabled ? MenuBarPalette.mutedText : MenuBarPalette.primaryText
    }

    private var iconColor: Color {
        if isHovering, !isDisabled { return MenuBarPalette.selectedRowText.opacity(isCopied ? 0.98 : 0.82) }
        return isCopied ? MenuBarPalette.connected : MenuBarPalette.secondaryText
    }

    private var rowBackground: Color {
        if isHovering, !isDisabled { return MenuBarPalette.selectedRow }
        if isCopied { return MenuBarPalette.connected.opacity(0.16) }
        return .clear
    }
}

private struct MenuBarListButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var title: String
    var shortcut: String?
    var isDisabled = false
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(primaryTextColor)
                Spacer(minLength: 0)
                if let shortcut {
                    Text(shortcut)
                        .font(.body)
                        .foregroundStyle(shortcutTextColor)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, MenuBarPalette.selectedRowContentVerticalPadding)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, MenuBarPalette.selectedRowHorizontalInset)
            .padding(.vertical, MenuBarPalette.selectedRowVerticalInset)
        }
        .buttonStyle(QuietPressButtonStyle(pressedScale: 0.985, pressedOpacity: 0.82))
        .disabled(isDisabled)
        .onHover { isHovering = $0 }
        .animation(EasyTierMotion.quick(reduceMotion: reduceMotion), value: isHovering)
    }

    private var primaryTextColor: Color {
        if isDisabled { return MenuBarPalette.mutedText }
        return isHovering ? MenuBarPalette.selectedRowText : MenuBarPalette.primaryText
    }

    private var shortcutTextColor: Color {
        if isDisabled { return MenuBarPalette.mutedText.opacity(0.7) }
        return isHovering ? MenuBarPalette.selectedRowText.opacity(0.72) : MenuBarPalette.mutedText
    }

    private var rowBackground: Color {
        if isDisabled { return .clear }
        return isHovering ? MenuBarPalette.selectedRow : .clear
    }
}

private struct MenuBarUpdateBanner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.body)
                    .foregroundStyle(.orange)
                Text("Update Available")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, MenuBarPalette.selectedRowContentVerticalPadding)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, MenuBarPalette.selectedRowHorizontalInset)
            .padding(.vertical, MenuBarPalette.selectedRowVerticalInset)
        }
        .buttonStyle(QuietPressButtonStyle(pressedScale: 0.985, pressedOpacity: 0.82))
        .onHover { isHovering = $0 }
        .animation(EasyTierMotion.quick(reduceMotion: reduceMotion), value: isHovering)
        .accessibilityLabel(Text("Update available"))
        .accessibilityHint(Text("Opens the software update sheet"))
    }

    private var rowBackground: Color {
        isHovering ? MenuBarPalette.selectedRow : Color.orange.opacity(0.1)
    }
}
