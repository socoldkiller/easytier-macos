import EasyTierShared
import AppKit
import ServiceManagement
import SwiftUI

@main
struct EasyTierApp: App {
    @NSApplicationDelegateAdaptor(EasyTierApplicationDelegate.self) private var appDelegate
    @State private var store = EasyTierAppStore()
    @State private var updater = SoftwareUpdateController()
    @State private var menuBarController = MenuBarStatusItemController()
    @State private var appearanceSettings = AppAppearanceSettings()

    init() {
        Self.runHelperCommandIfRequested()
    }

    var body: some Scene {
        Window("EasyTier", id: "main") {
            ContentView()
                .environment(store)
                .environment(updater)
                .environment(appearanceSettings)
                .background {
                    if appearanceSettings.glassEffectsEnabled {
                        FrostedWindowBackground()
                            .ignoresSafeArea()
                    } else {
                        Color(nsColor: .windowBackgroundColor)
                            .ignoresSafeArea()
                    }
                }
                .background(
                    MenuBarStatusItemBridge(
                        controller: menuBarController,
                        store: store,
                        updater: updater,
                        appearanceSettings: appearanceSettings,
                        connectionState: menuBarConnectionState
                    )
                    .frame(width: 0, height: 0)
                )
                .background(
                    WindowAccessor(glassEffectsEnabled: appearanceSettings.glassEffectsEnabled) { window in
                        configureMainWindow(window)
                    }
                    .frame(width: 0, height: 0)
                )
                .frame(minWidth: 900, minHeight: 620)
                .task { await store.load() }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Network") { store.addConfig() }
                    .keyboardShortcut("n")
            }

            CommandGroup(replacing: .saveItem) {
                Button("Save") { store.save() }
                    .keyboardShortcut("s")
            }

            CommandGroup(replacing: .appSettings) {
                Button("Settings...") { store.isShowingSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }

            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    store.isShowingAbout = true
                    updater.checkForUpdates()
                }
            }

            CommandGroup(replacing: .appTermination) {
                Button("Hide EasyTier") {
                    EasyTierApplicationDelegate.hideToMenuBar()
                }
                .keyboardShortcut("q")
            }
        }
    }

    private var menuBarConnectionState: ConnectionGlyphState {
        if store.lastError != nil { return .error }
        if store.isBusy { return .connecting }
        guard let instance = store.selectedRunningInstance else { return .idle }
        return store.instanceIsFullyConnected(instance) ? .connected : .connecting
    }

    private func configureMainWindow(_ window: NSWindow) {
        let frame = window.frame
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        if appearanceSettings.glassEffectsEnabled {
            window.isOpaque = false
            window.backgroundColor = .clear
        } else {
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
        }
        if window.frame != frame {
            window.setFrame(frame, display: true)
        }
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
            if arguments.contains("--register-helper"), let locationError = helperInstallLocationError() {
                fputs("helper command failed: \(locationError)\n", stderr)
                print("helper status: \(Self.describe(service.status))")
                Foundation.exit(EXIT_FAILURE)
            }
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

    private static func helperInstallLocationError() -> String? {
        if ProcessInfo.processInfo.environment["EASYTIER_ALLOW_UNSTABLE_HELPER_INSTALL"] == "1" {
            return nil
        }

        let path = Bundle.main.bundleURL.standardizedFileURL.path
        guard path == "/Applications/EasyTier.app" else {
            return "Move EasyTier.app to /Applications/EasyTier.app before installing the privileged helper. Current app path: \(path)"
        }
        return nil
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

@MainActor
final class EasyTierApplicationDelegate: NSObject, NSApplicationDelegate {
    private static var allowsTermination = false

    static func hideToMenuBar() {
        NSApp.hide(nil)
    }

    static func terminateNow() {
        allowsTermination = true
        NSApp.terminate(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            Foundation.exit(EXIT_SUCCESS)
        }
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        guard Self.allowsTermination else {
            Self.hideToMenuBar()
            return .terminateCancel
        }
        return .terminateNow
    }
}

private struct MenuBarStatusItemBridge: NSViewRepresentable {
    @Environment(\.openWindow) private var openWindow

    var controller: MenuBarStatusItemController
    var store: EasyTierAppStore
    var updater: SoftwareUpdateController
    var appearanceSettings: AppAppearanceSettings
    var connectionState: ConnectionGlyphState

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        controller.update(
            store: store,
            updater: updater,
            appearanceSettings: appearanceSettings,
            connectionState: connectionState,
            openMainWindow: openMainWindow
        )
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        controller.update(
            store: store,
            updater: updater,
            appearanceSettings: appearanceSettings,
            connectionState: connectionState,
            openMainWindow: openMainWindow
        )
    }

    private func openMainWindow() {
        NSApp.unhide(nil)
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
private final class MenuBarStatusItemController: NSObject {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var hostingController: NSHostingController<AnyView>?
    private var connectionState: ConnectionGlyphState = .idle
    private var activeNodeIndex = 0
    private var animationTask: Task<Void, Never>?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var resignActiveObserver: NSObjectProtocol?
    private var openMainWindowAction: (() -> Void)?

    private static let popoverSize = NSSize(width: 292, height: 370)
    private static let counterclockwiseNodeIndexes = [0, 1, 2]
    private static let stepDurationNanoseconds: UInt64 = 340_000_000

    override init() {
        super.init()
        popover.delegate = self
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = Self.popoverSize
    }

    func update(
        store: EasyTierAppStore,
        updater: SoftwareUpdateController,
        appearanceSettings: AppAppearanceSettings,
        connectionState: ConnectionGlyphState,
        openMainWindow: @escaping () -> Void
    ) {
        installStatusItemIfNeeded()
        openMainWindowAction = openMainWindow

        if self.connectionState != connectionState {
            self.connectionState = connectionState
            activeNodeIndex = 0
            updateAnimation()
            refreshStatusImage()
        }

        updatePopoverContent(store: store, updater: updater, appearanceSettings: appearanceSettings)
    }

    func closePopover() {
        popover.performClose(nil)
        removeDismissHandlers()
    }

    private func installStatusItemIfNeeded() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
        }
        statusItem = item
    }

    private func updatePopoverContent(
        store: EasyTierAppStore,
        updater: SoftwareUpdateController,
        appearanceSettings: AppAppearanceSettings
    ) {
        guard hostingController == nil else {
            popover.contentSize = Self.popoverSize
            return
        }

        let content = MenuBarContent(
            openMainWindowAction: { [weak self] in self?.openMainWindowAction?() },
            dismissMenuBarAction: { [weak self] in self?.closePopover() }
        )
        .environment(store)
        .environment(updater)
        .environment(appearanceSettings)

        let rootView = AnyView(content)
        let controller = NSHostingController(rootView: rootView)
        controller.view.frame = NSRect(origin: .zero, size: Self.popoverSize)
        hostingController = controller
        popover.contentViewController = controller
        popover.contentSize = Self.popoverSize
    }

    private func refreshStatusImage() {
        let currentActiveNodeIndex: Int?
        if connectionState == .connecting {
            currentActiveNodeIndex = Self.counterclockwiseNodeIndexes[activeNodeIndex % Self.counterclockwiseNodeIndexes.count]
        } else {
            currentActiveNodeIndex = nil
        }

        guard let button = statusItem?.button else { return }
        button.image = MenuBarConnectionIcon.image(
            for: connectionState,
            activeNodeIndex: currentActiveNodeIndex,
            appearance: button.effectiveAppearance
        )
    }

    private func updateAnimation() {
        animationTask?.cancel()

        guard connectionState == .connecting else { return }
        animationTask = Task { [weak self] in
            await self?.runConnectingAnimation()
        }
    }

    private func runConnectingAnimation() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: Self.stepDurationNanoseconds)
            } catch {
                break
            }
            activeNodeIndex = (activeNodeIndex + 1) % Self.counterclockwiseNodeIndexes.count
            refreshStatusImage()
        }
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let button = statusItem?.button else { return }

        if popover.isShown {
            closePopover()
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            installDismissHandlers()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func installDismissHandlers() {
        removeDismissHandlers()

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.closePopoverIfClickIsOutside(event)
            return event
        }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.closePopover()
            }
        }

        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.closePopover()
            }
        }
    }

    private func removeDismissHandlers() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
        if let resignActiveObserver {
            NotificationCenter.default.removeObserver(resignActiveObserver)
            self.resignActiveObserver = nil
        }
    }

    private func closePopoverIfClickIsOutside(_ event: NSEvent) {
        guard popover.isShown else { return }
        guard !eventIsInsidePopover(event), !eventIsInsideStatusItem(event) else { return }
        closePopover()
    }

    private func eventIsInsidePopover(_ event: NSEvent) -> Bool {
        guard let popoverWindow = popover.contentViewController?.view.window else { return false }
        return event.window === popoverWindow
    }

    private func eventIsInsideStatusItem(_ event: NSEvent) -> Bool {
        guard let button = statusItem?.button, event.window === button.window else { return false }
        let point = button.convert(event.locationInWindow, from: nil)
        return button.bounds.contains(point)
    }
}

extension MenuBarStatusItemController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        removeDismissHandlers()
    }
}

private enum MenuBarConnectionIcon {
    static func image(
        for state: ConnectionGlyphState,
        activeNodeIndex: Int? = nil,
        appearance: NSAppearance
    ) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 18))
        image.lockFocus()
        defer { image.unlockFocus() }

        appearance.performAsCurrentDrawingAppearance {
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
        let radius: CGFloat = 2.5
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
            return baseColor(for: state)
        case .error:
            return index == errorNodeIndex ? baseColor(for: state) : nil
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
        case .idle:
            return .secondaryLabelColor
        case .connecting:
            return .systemBlue
        case .connected:
            return NSColor(srgbRed: 0.35, green: 0.78, blue: 0.42, alpha: 1)
        case .error:
            return .systemRed
        }
    }

    private static let errorNodeIndex = 2
}

private struct MenuBarContent: View {
    @Environment(EasyTierAppStore.self) private var store
    @Environment(AppAppearanceSettings.self) private var appearanceSettings
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
                        .padding(4)
                        .background(connectionSwitchBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(QuietPressButtonStyle(pressedScale: 0.94, pressedOpacity: 0.86))
                .disabled(store.isBusy || store.selectedConfig == nil)
                .onHover { isConnectionSwitchHovering = $0 }
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

            MenuBarListButton(title: "About EasyTier") {
                openMainWindow()
                store.isShowingAbout = true
                dismissMenuBar()
            }

            MenuBarListButton(title: "Install on Linux") {
                openMainWindow()
                store.isShowingLinuxInstallGuide = true
                dismissMenuBar()
            }

            MenuBarDivider()

            MenuBarListButton(title: windowEffectTitle) {
                appearanceSettings.glassEffectsEnabled.toggle()
            }

            MenuBarListButton(title: "Settings...", shortcut: "⌘ ,") {
                openMainWindow()
                store.isShowingSettings = true
                dismissMenuBar()
            }

            MenuBarDivider()

            MenuBarListButton(title: "Hide EasyTier", shortcut: "⌘ Q") {
                EasyTierApplicationDelegate.hideToMenuBar()
            }
        }
        .frame(width: 292)
        .foregroundStyle(MenuBarPalette.primaryText)
        .background(MenuBarPanelBackground())
        .presentedSurfaceMotion()
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

    private var windowEffectTitle: String {
        "Window Effect: \(appearanceSettings.glassEffectsEnabled ? "Frosted Glass" : "Traditional")"
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

    private var connectionSwitchBackground: Color {
        guard isConnectionSwitchHovering, !store.isBusy, store.selectedConfig != nil else { return .clear }
        return MenuBarPalette.selectedRow
    }

    private var selectedNetworkSubtitle: String {
        if store.selectedConfig == nil { return "Select a network" }
        guard let instance = selectedRunningInstance else { return "Disconnected" }
        return store.instanceIsFullyConnected(instance) ? "Connected" : "Connecting"
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
        openMainWindow()
        dismissMenuBar()
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

    private func firstNonEmpty(_ values: String?...) -> String? {
        values.lazy.compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.first
    }
}

private enum MenuBarPalette {
    static let primaryText = Color.primary
    static let secondaryText = Color.secondary
    static let mutedText = Color.secondary.opacity(0.6)
    static let divider = Color.primary.opacity(0.14)
    static let rowHighlight = Color.primary.opacity(0.08)
    static let selectedRow = Color(red: 0.10, green: 0.37, blue: 0.78)
    static let selectedRowHorizontalInset: CGFloat = 12
    static let selectedRowVerticalInset: CGFloat = 5
    static let selectedRowContentVerticalPadding: CGFloat = 4
    static let connected = Color(red: 0.35, green: 0.78, blue: 0.42)
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
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
    }
}

struct FrostedWindowBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        configure(view)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        configure(view)
    }

    private func configure(_ view: NSVisualEffectView) {
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
    }
}

struct GlassFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Color.primary.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.primary.opacity(0.1), lineWidth: 0.5)
            }
    }
}

extension TextFieldStyle where Self == GlassFieldStyle {
    static var glassField: GlassFieldStyle { .init() }
}

private struct WindowAccessor: NSViewRepresentable {
    var glassEffectsEnabled: Bool
    var configure: (NSWindow) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                configure(window)
                context.coordinator.lastAppliedGlass = glassEffectsEnabled
            }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard context.coordinator.lastAppliedGlass != glassEffectsEnabled else { return }
        guard let window = view.window else { return }
        configure(window)
        context.coordinator.lastAppliedGlass = glassEffectsEnabled
    }

    final class Coordinator {
        var lastAppliedGlass: Bool?
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

    var isOn: Bool
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
        .animation(EasyTierMotion.selection(reduceMotion: reduceMotion), value: isOn)
        .accessibilityLabel(isOn ? Text("Disconnect") : Text("Connect"))
    }

    private var trackColor: Color {
        isOn ? MenuBarPalette.connected.opacity(0.82) : MenuBarPalette.rowHighlight
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
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(primaryTextColor)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.system(size: 13.5, weight: .regular))
                            .foregroundStyle(secondaryTextColor)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)

                    if !canSwitch {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 16, weight: .medium))
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
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(inlineChevronColor(isHovering: isHovering.wrappedValue))
                .frame(width: 24, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(QuietPressButtonStyle(pressedScale: 0.9, pressedOpacity: 0.76))
        .onHover { isHovering.wrappedValue = $0 }
        .help(help)
    }

    private var primaryTextColor: Color {
        isRowActive ? Color.white.opacity(0.96) : MenuBarPalette.primaryText
    }

    private var secondaryTextColor: Color {
        isRowActive ? Color.white.opacity(0.78) : MenuBarPalette.secondaryText
    }

    private var rowBackground: Color {
        isRowActive ? MenuBarPalette.selectedRow : .clear
    }

    private var isRowActive: Bool {
        isOpenHovering || isPreviousHovering || isNextHovering
    }

    private func inlineChevronColor(isHovering: Bool) -> Color {
        isRowActive ? Color.white.opacity(isHovering ? 1.0 : 0.92) : MenuBarPalette.primaryText
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
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: isCopied ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.system(size: 12.5, weight: .semibold))
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
    }

    private var titleColor: Color {
        if isHovering, !isDisabled { return Color.white.opacity(0.96) }
        return isDisabled ? MenuBarPalette.mutedText : MenuBarPalette.primaryText
    }

    private var iconColor: Color {
        if isHovering, !isDisabled { return Color.white.opacity(isCopied ? 0.98 : 0.82) }
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
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(primaryTextColor)
                Spacer(minLength: 0)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 13, weight: .regular))
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
        .onHover { isHovering = $0 }
        .animation(EasyTierMotion.quick(reduceMotion: reduceMotion), value: isHovering)
    }

    private var primaryTextColor: Color {
        isHovering ? Color.white.opacity(0.96) : MenuBarPalette.primaryText
    }

    private var shortcutTextColor: Color {
        isHovering ? Color.white.opacity(0.72) : MenuBarPalette.mutedText
    }

    private var rowBackground: Color {
        isHovering ? MenuBarPalette.selectedRow : .clear
    }
}
