import EasyTierShared
import AppKit
import ServiceManagement
import SwiftUI

@main
struct EasyTierApp: App {
    @State private var store = EasyTierAppStore()

    init() {
        Self.runHelperCommandIfRequested()
    }

    var body: some Scene {
        Window("EasyTier", id: "main") {
            ContentView()
                .environment(store)
                .frame(minWidth: 900, minHeight: 620)
                .task { await store.load() }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Network") { store.addConfig() }
                    .keyboardShortcut("n")
            }

            CommandGroup(replacing: .saveItem) {
                Button("Save") { store.save() }
                    .keyboardShortcut("s")
            }
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(store)
        } label: {
            MenuBarConnectionLabel(state: menuBarConnectionState)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarConnectionState: ConnectionGlyphState {
        if store.isBusy { return .connecting }
        guard !store.instances.isEmpty else { return .idle }
        return allRunningInstancesConnected ? .connected : .connecting
    }

    private var allRunningInstancesConnected: Bool {
        store.instances.allSatisfy { store.instanceIsFullyConnected($0) }
    }

    private static func runHelperCommandIfRequested() {
        let arguments = CommandLine.arguments
        if arguments.contains("--ping-helper") {
            runAsyncHelperCommandAndExit {
                try await PrivilegedEasyTierClient().helperPingPayload()
            }
        }

        guard arguments.contains("--register-helper") || arguments.contains("--unregister-helper") || arguments.contains("--helper-status") else { return }

        let service = SMAppService.daemon(plistName: EasyTierPrivilegedHelperConstants.launchDaemonPlistName)
        do {
            if arguments.contains("--unregister-helper") || arguments.contains("--register-helper") {
                try? service.unregister()
            }
            if arguments.contains("--register-helper") {
                try service.register()
            }
            print("helper status: \(Self.describe(service.status))")
            Foundation.exit(EXIT_SUCCESS)
        } catch {
            fputs("helper command failed: \(error.localizedDescription)\n", stderr)
            print("helper status: \(Self.describe(service.status))")
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: "notRegistered"
        case .enabled: "enabled"
        case .requiresApproval: "requiresApproval"
        case .notFound: "notFound"
        @unknown default: "unknown"
        }
    }

    private static func runAsyncHelperCommandAndExit(_ command: @escaping () async throws -> String) {
        Task {
            do {
                let payload = try await command()
                print(payload)
                Foundation.exit(EXIT_SUCCESS)
            } catch {
                fputs("helper command failed: \(error.localizedDescription)\n", stderr)
                Foundation.exit(EXIT_FAILURE)
            }
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 30))
        fputs("helper command timed out\n", stderr)
        Foundation.exit(EXIT_FAILURE)
    }
}

private struct MenuBarConnectionLabel: View {
    var state: ConnectionGlyphState

    @State private var activeNodeIndex = 0

    var body: some View {
        Image(nsImage: MenuBarConnectionIcon.image(for: state, activeNodeIndex: currentActiveNodeIndex))
            .renderingMode(.template)
            .task(id: state) {
                await runConnectingAnimationIfNeeded()
            }
    }

    private var currentActiveNodeIndex: Int? {
        guard state == .connecting else { return nil }
        return Self.clockwiseNodeIndexes[activeNodeIndex % Self.clockwiseNodeIndexes.count]
    }

    private static let clockwiseNodeIndexes = [0, 2, 1]
    private static let stepDurationNanoseconds: UInt64 = 340_000_000

    private func runConnectingAnimationIfNeeded() async {
        guard state == .connecting else {
            activeNodeIndex = 0
            return
        }

        activeNodeIndex = 0
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: Self.stepDurationNanoseconds)
            } catch {
                break
            }
            activeNodeIndex = (activeNodeIndex + 1) % Self.clockwiseNodeIndexes.count
        }
    }
}

private enum MenuBarConnectionIcon {
    static func image(for state: ConnectionGlyphState, activeNodeIndex: Int? = nil) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 18))
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.black.setFill()
        NSColor.black.withAlphaComponent(lineAlpha(for: state)).setStroke()

        let nodes = [
            CGPoint(x: 11, y: 14),
            CGPoint(x: 5, y: 4),
            CGPoint(x: 17, y: 4),
        ]

        func addSegment(from start: CGPoint, to end: CGPoint) {
            let dx = end.x - start.x
            let dy = end.y - start.y
            let length = max(sqrt(dx * dx + dy * dy), 0.001)
            let gap: CGFloat = 5.8
            let inset = min(gap, length * 0.43)
            let unit = CGPoint(x: dx / length, y: dy / length)
            let path = NSBezierPath()
            path.lineWidth = 1.35
            path.lineCapStyle = .round
            path.move(to: CGPoint(x: start.x + unit.x * inset, y: start.y + unit.y * inset))
            path.line(to: CGPoint(x: end.x - unit.x * inset, y: end.y - unit.y * inset))
            path.stroke()
        }

        switch state {
        case .idle, .error:
            addSegment(from: nodes[0], to: nodes[1])
        case .connecting, .connected:
            addSegment(from: nodes[0], to: nodes[1])
            addSegment(from: nodes[1], to: nodes[2])
            addSegment(from: nodes[2], to: nodes[0])
        }

        for (index, point) in nodes.enumerated() {
            NSColor.black.withAlphaComponent(nodeAlpha(for: state, index: index, activeNodeIndex: activeNodeIndex)).setFill()
            NSBezierPath(ovalIn: NSRect(x: point.x - 2.45, y: point.y - 2.45, width: 4.9, height: 4.9)).fill()
        }

        image.isTemplate = true
        return image
    }

    private static func lineAlpha(for state: ConnectionGlyphState) -> CGFloat {
        switch state {
        case .idle: 0.28
        case .connecting: 0.42
        case .connected: 0.74
        case .error: 0.42
        }
    }

    private static func nodeAlpha(for state: ConnectionGlyphState, index: Int, activeNodeIndex: Int?) -> CGFloat {
        switch state {
        case .idle:
            return 0.42
        case .connecting:
            return index == activeNodeIndex ? 0.92 : 0.34
        case .connected:
            return 0.92
        case .error:
            return index == 2 ? 0.92 : 0.44
        }
    }
}

private struct MenuBarContent: View {
    @Environment(EasyTierAppStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var copiedDeviceAddress = false
    @State private var copyFeedbackToken = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("EasyTier")
                        .font(.system(size: 14, weight: .medium))
                    HStack(spacing: 6) {
                        Circle()
                            .fill(connectionIndicatorColor)
                            .frame(width: 6, height: 6)
                        Text(connectionSubtitle)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(MenuBarPalette.secondaryText)
                    }
                }

                Spacer(minLength: 0)

                Button(action: toggleConnection) {
                    MenuBarConnectionSwitch(isOn: hasRunningInstances, isBusy: store.isBusy)
                }
                    .buttonStyle(.plain)
                    .disabled(store.isBusy || (!hasRunningInstances && store.selectedConfig == nil))
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 10)

            MenuBarDivider()

            Button(action: openMainWindow) {
                HStack(spacing: 10) {
                    MenuBarNetworkAvatar(state: selectedNetworkState)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(currentNetworkName)
                            .font(.system(size: 13.5, weight: .medium))
                            .lineLimit(1)
                        Text(selectedNetworkSubtitle)
                            .font(.system(size: 13.5, weight: .regular))
                            .foregroundStyle(MenuBarPalette.secondaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(MenuBarPalette.primaryText)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)

            MenuBarDivider()

            MenuBarCopyRow(title: deviceTitle, isCopied: copiedDeviceAddress, isDisabled: deviceCopyAddress == nil) {
                copyDeviceAddress()
            }
            MenuBarPlainRow(title: devicesTitle, isMuted: true)

            MenuBarDivider()

            MenuBarListButton(title: "About EasyTier") {
                openMainWindow()
                store.isShowingAbout = true
            }

            MenuBarDivider()

            MenuBarListButton(title: "Settings...", shortcut: "⌘ ,") {
                store.selectedTab = .config
                openMainWindow()
            }

            MenuBarDivider()

            MenuBarListButton(title: "Quit", shortcut: "⌘ Q") {
                NSApp.terminate(nil)
            }
        }
        .frame(width: 320)
        .foregroundStyle(MenuBarPalette.primaryText)
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
    }

    private var hasRunningInstances: Bool {
        !store.instances.isEmpty
    }

    private var selectedNetworkState: ConnectionGlyphState {
        if store.lastError != nil { return .error }
        if store.isBusy { return .connecting }
        guard let instance = selectedRunningInstance else { return .idle }
        return store.instanceIsFullyConnected(instance) ? .connected : .connecting
    }

    private var selectedRunningInstance: NetworkInstance? {
        guard let config = store.selectedConfig else { return nil }
        return store.runningInstance(matching: config)
    }

    private var allRunningInstancesConnected: Bool {
        store.instances.allSatisfy { store.instanceIsFullyConnected($0) }
    }

    private var currentNetworkName: String {
        store.selectedConfig?.network_name ?? "No network selected"
    }

    private var deviceTitle: String {
        "This Device: \(deviceName) (\(deviceAddress))"
    }

    private var deviceName: String {
        let runtimeHostname = store.selectedRunningInstance?.detail?.my_node_info?.hostname
        let configHostname = store.selectedConfig?.hostname
        return firstNonEmpty(runtimeHostname, configHostname, Host.current().localizedName) ?? "This Mac"
    }

    private var deviceAddress: String {
        let node = store.selectedRunningInstance?.detail?.my_node_info
        return firstNonEmpty(node?.virtual_ipv4?.displayString, node?.ipv4_addr) ?? "-"
    }

    private var deviceCopyAddress: String? {
        let address = deviceAddress.split(separator: "/", maxSplits: 1).first.map(String.init) ?? deviceAddress
        return address == "-" ? nil : address
    }

    private var devicesTitle: String {
        let count = store.selectedMemberStatuses.count
        if count > 0 { return "\(count) Devices" }
        return hasRunningInstances ? "Loading Devices..." : "No Devices"
    }

    private var connectionSubtitle: String {
        if store.isBusy { return "Working" }
        if store.lastError != nil { return "Needs Attention" }
        guard hasRunningInstances else { return "Not Connected" }
        return allRunningInstancesConnected ? "Connected" : "Connecting"
    }

    private var connectionIndicatorColor: Color {
        if store.lastError != nil { return .orange }
        if store.isBusy { return .yellow.opacity(0.82) }
        guard hasRunningInstances else { return MenuBarPalette.mutedText }
        return allRunningInstancesConnected ? MenuBarPalette.connected : .yellow.opacity(0.82)
    }

    private var selectedNetworkSubtitle: String {
        if store.selectedConfig == nil { return "Select a network" }
        guard let instance = selectedRunningInstance else { return "Disconnected" }
        return store.instanceIsFullyConnected(instance) ? "Connected" : "Connecting"
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func toggleConnection() {
        Task {
            if hasRunningInstances {
                await store.stopAll()
            } else {
                await store.runSelectedConfig()
            }
        }
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

    private func firstNonEmpty(_ values: String?...) -> String? {
        values.lazy.compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.first
    }
}

private enum MenuBarPalette {
    static let primaryText = Color.white.opacity(0.88)
    static let secondaryText = Color.white.opacity(0.58)
    static let mutedText = Color.white.opacity(0.34)
    static let divider = Color.white.opacity(0.16)
    static let rowHighlight = Color.white.opacity(0.08)
    static let connected = Color(red: 0.35, green: 0.78, blue: 0.42)
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
    var isOn: Bool
    var isBusy: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(trackColor)
                .overlay {
                    Capsule()
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.6)
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
        .animation(.easeOut(duration: 0.16), value: isOn)
        .accessibilityLabel(isOn ? Text("Disconnect") : Text("Connect"))
    }

    private var trackColor: Color {
        isOn ? MenuBarPalette.connected.opacity(0.82) : Color.white.opacity(0.12)
    }

    private var knobColor: Color {
        Color.white.opacity(0.92)
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
        case .connected: Color.white.opacity(0.16)
        case .connecting: Color.white.opacity(0.13)
        case .error: Color.white.opacity(0.12)
        case .idle: Color.white.opacity(0.09)
        }
    }
}

private struct MenuBarPlainRow: View {
    var title: String
    var isMuted = false

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isMuted ? MenuBarPalette.mutedText : MenuBarPalette.primaryText)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

private struct MenuBarCopyRow: View {
    var title: String
    var isCopied: Bool
    var isDisabled: Bool
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isDisabled ? MenuBarPalette.mutedText : MenuBarPalette.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: isCopied ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(isCopied ? MenuBarPalette.connected : MenuBarPalette.secondaryText)
                    .frame(width: 18, height: 18)
                    .opacity(isDisabled ? 0 : 1)
                    .contentTransition(.symbolEffect(.replace))
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.14), value: isCopied)
        .animation(.easeOut(duration: 0.14), value: isHovering)
        .help("Copy IP address")
    }

    private var rowBackground: Color {
        if isCopied { return MenuBarPalette.connected.opacity(0.16) }
        if isHovering, !isDisabled { return MenuBarPalette.rowHighlight }
        return .clear
    }
}

private struct MenuBarListButton: View {
    var title: String
    var shortcut: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.system(size: 13, weight: .regular))
                Spacer(minLength: 0)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(MenuBarPalette.mutedText)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
    }
}
