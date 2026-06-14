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
        if store.lastError != nil { return .error }
        if store.isBusy { return .connecting }
        guard let instance = store.selectedRunningInstance else { return .idle }
        return store.instanceIsFullyConnected(instance) ? .connected : .connecting
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
            .task(id: state) {
                await runConnectingAnimationIfNeeded()
            }
    }

    private var currentActiveNodeIndex: Int? {
        guard state == .connecting else { return nil }
        return Self.counterclockwiseNodeIndexes[activeNodeIndex % Self.counterclockwiseNodeIndexes.count]
    }

    private static let counterclockwiseNodeIndexes = [0, 1, 2]
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
            activeNodeIndex = (activeNodeIndex + 1) % Self.counterclockwiseNodeIndexes.count
        }
    }
}

private enum MenuBarConnectionIcon {
    static func image(for state: ConnectionGlyphState, activeNodeIndex: Int? = nil) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 18))
        image.lockFocus()
        defer { image.unlockFocus() }

        let nodeCenters = [
            CGPoint(x: 11, y: 14),
            CGPoint(x: 5, y: 4),
            CGPoint(x: 17, y: 4),
        ]

        drawDashedSegment(from: nodeCenters[0], to: nodeCenters[1], state: state)
        drawDashedSegment(from: nodeCenters[1], to: nodeCenters[2], state: state)
        drawDashedSegment(from: nodeCenters[2], to: nodeCenters[0], state: state)

        for (index, point) in nodeCenters.enumerated() {
            drawNode(at: point, state: state, index: index, activeNodeIndex: activeNodeIndex)
        }

        image.isTemplate = false
        return image
    }

    private static func drawDashedSegment(from start: CGPoint, to end: CGPoint, state: ConnectionGlyphState) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = max(sqrt(dx * dx + dy * dy), 0.001)
        let inset = min(CGFloat(4.35), length * 0.43)
        let unit = CGPoint(x: dx / length, y: dy / length)
        let path = NSBezierPath()

        path.lineWidth = 1.25
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.setLineDash([1.3, 1.75], count: 2, phase: 0)
        path.move(to: CGPoint(x: start.x + unit.x * inset, y: start.y + unit.y * inset))
        path.line(to: CGPoint(x: end.x - unit.x * inset, y: end.y - unit.y * inset))

        baseColor(for: state).withAlphaComponent(lineAlpha(for: state)).setStroke()
        path.stroke()
    }

    private static func drawNode(at point: CGPoint, state: ConnectionGlyphState, index: Int, activeNodeIndex: Int?) {
        let radius: CGFloat = 2.0
        let stroke = nodeStrokeColor(for: state, index: index)
            .withAlphaComponent(nodeStrokeAlpha(for: state, index: index, activeNodeIndex: activeNodeIndex))
        let fill = nodeFillColor(for: state, index: index, activeNodeIndex: activeNodeIndex)

        drawCircle(center: point, radius: radius, fill: fill, stroke: (stroke, 1.55))
    }

    private static func drawCircle(center: CGPoint, radius: CGFloat, fill: NSColor?, stroke: (color: NSColor, width: CGFloat)?) {
        let rect = NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        let path = NSBezierPath(ovalIn: rect)

        if let fill {
            fill.setFill()
            path.fill()
        }

        if let stroke {
            stroke.color.setStroke()
            path.lineWidth = stroke.width
            path.stroke()
        }
    }

    private static func nodeFillColor(for state: ConnectionGlyphState, index: Int, activeNodeIndex: Int?) -> NSColor? {
        switch state {
        case .idle:
            return nil
        case .connecting:
            return index == activeNodeIndex ? baseColor(for: state) : nil
        case .connected:
            return .systemGreen
        case .error:
            return index == errorNodeIndex ? .systemRed : nil
        }
    }

    private static func nodeStrokeColor(for state: ConnectionGlyphState, index: Int) -> NSColor {
        return baseColor(for: state)
    }

    private static func nodeStrokeAlpha(for state: ConnectionGlyphState, index: Int, activeNodeIndex: Int?) -> CGFloat {
        switch state {
        case .idle:
            return 0.92
        case .connecting:
            return index == activeNodeIndex ? 1.0 : 0.80
        case .connected:
            return 1.0
        case .error:
            return index == errorNodeIndex ? 1.0 : 0.80
        }
    }

    private static func lineAlpha(for state: ConnectionGlyphState) -> CGFloat {
        switch state {
        case .idle: 0.58
        case .connecting: 0.68
        case .connected: 1.0
        case .error: 0.68
        }
    }

    private static func baseColor(for state: ConnectionGlyphState) -> NSColor {
        switch state {
        case .idle, .connecting, .connected, .error:
            return .black
        }
    }

    private static let errorNodeIndex = 2
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
                    MenuBarConnectionSwitch(isOn: store.selectedConfigIsRunning, isBusy: store.isBusy)
                }
                    .buttonStyle(.plain)
                    .disabled(store.isBusy || store.selectedConfig == nil)
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
                open: openMainWindow,
                previous: selectPreviousNetwork,
                next: selectNextNetwork
            )

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
        .frame(width: 292)
        .foregroundStyle(MenuBarPalette.primaryText)
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
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
        return store.selectedConfigIsRunning ? "Loading Devices..." : "No Devices"
    }

    private var connectionSubtitle: String {
        if store.isBusy { return "Working" }
        if store.lastError != nil { return "Needs Attention" }
        guard store.selectedConfig != nil else { return "No Network" }
        guard let instance = selectedRunningInstance else { return "Not Connected" }
        return store.instanceIsFullyConnected(instance) ? "Connected" : "Connecting"
    }

    private var connectionIndicatorColor: Color {
        if store.lastError != nil { return .orange }
        if store.isBusy { return .yellow.opacity(0.82) }
        guard let instance = selectedRunningInstance else { return MenuBarPalette.mutedText }
        return store.instanceIsFullyConnected(instance) ? MenuBarPalette.connected : .yellow.opacity(0.82)
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

private struct MenuBarNetworkRow: View {
    var name: String
    var subtitle: String
    var state: ConnectionGlyphState
    var canSwitch: Bool
    var open: () -> Void
    var previous: () -> Void
    var next: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: open) {
                HStack(spacing: 10) {
                    MenuBarNetworkAvatar(state: state)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .font(.system(size: 13.5, weight: .medium))
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.system(size: 13.5, weight: .regular))
                            .foregroundStyle(MenuBarPalette.secondaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)

                    if !canSwitch {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(MenuBarPalette.primaryText)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)

            if canSwitch {
                HStack(spacing: 2) {
                    MenuBarIconButton(systemName: "chevron.left", help: "Previous network", action: previous)
                    MenuBarIconButton(systemName: "chevron.right", help: "Next network", action: next)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private struct MenuBarIconButton: View {
    var systemName: String
    var help: String
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MenuBarPalette.primaryText)
                .frame(width: 24, height: 28)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .background(buttonBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.14), value: isHovering)
        .help(help)
    }

    private var buttonBackground: Color {
        isHovering ? MenuBarPalette.rowHighlight : Color.white.opacity(0.04)
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
