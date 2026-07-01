import EasyTierShared
import EasyTierRuntime
import AppKit
import ServiceManagement
import SwiftUI

@main
struct EasyTierApp: App {
    @NSApplicationDelegateAdaptor(EasyTierApplicationDelegate.self) private var appDelegate
    @State private var store = EasyTierAppStore(
        inProcessClient: StaticEasyTierFFIClient(),
        helperRegistration: HelperRegistrationService()
    )
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
                .easyTierWindowBackground(glassEffectsEnabled: appearanceSettings.glassEffectsEnabled)
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
                    WindowAccessor { window in
                        configureMainWindow(window, glassEffectsEnabled: appearanceSettings.glassEffectsEnabled)
                    }
                    .frame(width: 0, height: 0)
                )
                .frame(minWidth: 900, minHeight: 620)
                .task {
                    EasyTierApplicationDelegate.installQuitPreparation {
                        await store.prepareForAppQuit()
                    }
                    await store.load()
                }
        }
        .windowToolbarStyle(.unified)

        Window("EasyTier", id: "settings") {
            EasyTierSettingsSheet(initialTab: .general, mode: store.mode, magicDNSSettings: store.magicDNSSettings) { mode, magicDNSSettings in
                Task { await store.applyMode(mode, magicDNSSettings: magicDNSSettings) }
            }
            .environment(store)
            .environment(updater)
            .environment(appearanceSettings)
            .easyTierWindowBackground(glassEffectsEnabled: appearanceSettings.glassEffectsEnabled)
            .background(
                WindowAccessor { window in
                    configureMainWindow(window, glassEffectsEnabled: appearanceSettings.glassEffectsEnabled)
                }
                .frame(width: 0, height: 0)
            )
        }
        .windowToolbarStyle(.unified)
        .windowResizability(.contentSize)

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
                Button("Quit EasyTier") {
                    EasyTierApplicationDelegate.quitEasyTier()
                }
                .keyboardShortcut("q")
            }
        }
    }

    private var menuBarConnectionState: ConnectionGlyphState {
        if store.lastError != nil { return .error }
        if store.isBusy || store.isQuitting { return .connecting }
        guard var instance = store.selectedRunningInstance else { return .idle }
        instance.detail = store.selectedRuntimeDetail
        return store.instanceIsFullyConnected(instance) ? .connected : .connecting
    }

    private func configureMainWindow(_ window: NSWindow, glassEffectsEnabled: Bool) {
        let frame = window.frame
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.isOpaque = !glassEffectsEnabled
        window.backgroundColor = glassEffectsEnabled ? .clear : .windowBackgroundColor
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

        if arguments.contains("--register-helper") || arguments.contains("--unregister-helper") || arguments.contains("--helper-status") {
            if arguments.contains("--register-helper"), let locationError = helperInstallLocationError() {
                fputs("helper command failed: \(locationError)\n", stderr)
                print("helper status: \(Self.currentHelperStatusDescription())")
                Foundation.exit(EXIT_FAILURE)
            }

            runAsyncHelperCommandAndExit { @MainActor in
                let service = SMAppService.daemon(plistName: EasyTierPrivilegedHelperConstants.launchDaemonPlistName)
                if arguments.contains("--unregister-helper") || arguments.contains("--register-helper") {
                    try? await service.unregister()
                }
                if arguments.contains("--unregister-helper"),
                   LegacyPrivilegedHelperService.isInstalled,
                   ProcessInfo.processInfo.environment["EASYTIER_SKIP_LEGACY_HELPER_UNINSTALL"] != "1" {
                    try LegacyPrivilegedHelperService.uninstallUsingAdministratorPrivileges()
                }
                let registration = HelperRegistrationService()
                if arguments.contains("--register-helper") {
                    try await registration.ensureRegistered()
                } else {
                    await registration.refresh()
                }
                return "helper status: \(Self.describe(registration.state))"
            }
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

    private static func describe(_ state: HelperRegistrationService.State) -> String {
        switch state {
        case .notRegistered: "notRegistered"
        case .registering: "registering"
        case .requiresApproval: "requiresApproval"
        case .enabled: "enabled"
        case .notFound: "notFound"
        case .error: "error"
        }
    }

    private static func currentHelperStatusDescription() -> String {
        if LegacyPrivilegedHelperService.shouldUseLegacyInstaller {
            return LegacyPrivilegedHelperService.isInstalled ? "enabled" : "notRegistered"
        }
        let service = SMAppService.daemon(plistName: EasyTierPrivilegedHelperConstants.launchDaemonPlistName)
        return describe(service.status)
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
    private static var quitPreparation: (() async -> Void)?
    private static var quitTask: Task<Void, Never>?

    static func installQuitPreparation(_ preparation: @escaping () async -> Void) {
        quitPreparation = preparation
    }

    static func hideToMenuBar() {
        NSApp.hide(nil)
    }

    static func quitEasyTier() {
        guard quitTask == nil else { return }
        quitTask = Task {
            await quitPreparation?()
            terminateNow()
            quitTask = nil
        }
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
            Self.quitEasyTier()
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
        }
        refreshStatusImage()

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
    static let canvas: CGFloat = 22
    static let nodeRadius: CGFloat = 2.95
    static let nodeStroke: CGFloat = 1.75
    static let lineWidth: CGFloat = 1.05
    static let lineInset: CGFloat = 2.85

    static let nodeCenters: [CGPoint] = [
        CGPoint(x: 11, y: 17.15),
        CGPoint(x: 4.25, y: 3.7),
        CGPoint(x: 17.75, y: 3.7),
    ]
    static let segments: [(Int, Int)] = [(0, 1), (1, 2), (2, 0)]

    static func image(
        for state: ConnectionGlyphState,
        activeNodeIndex: Int? = nil,
        appearance: NSAppearance
    ) -> NSImage {
        let image = NSImage(size: NSSize(width: canvas, height: canvas))
        image.lockFocus()
        defer { image.unlockFocus() }

        appearance.performAsCurrentDrawingAppearance {
            if state == .connecting {
                for (a, b) in segments {
                    drawSegment(from: nodeCenters[a], to: nodeCenters[b], color: lineColor(for: state))
                }
            }

            for (segIndex, (a, b)) in segments.enumerated() {
                switch state {
                case .idle, .connected, .error:
                    drawSegment(from: nodeCenters[a], to: nodeCenters[b], color: lineColor(for: state))
                case .connecting:
                    if let active = activeNodeIndex, segIndex == active {
                        drawSegment(from: nodeCenters[a], to: nodeCenters[b],
                                    dashed: true, color: statusColor(for: state) ?? .systemOrange)
                    }
                }
            }

            for (index, point) in nodeCenters.enumerated() {
                let fill: NSColor?
                switch state {
                case .idle:
                    fill = nil
                case .connecting:
                    fill = (index == activeNodeIndex) ? statusColor(for: state) : nil
                case .connected, .error:
                    fill = statusColor(for: state)
                }
                drawNode(at: point, fill: fill)
            }
        }

        image.isTemplate = false
        return image
    }

    private static func drawSegment(from start: CGPoint, to end: CGPoint, dashed: Bool = false, color: NSColor) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = max(sqrt(dx * dx + dy * dy), 0.001)
        let inset = min(lineInset, length * 0.43)
        let unit = CGPoint(x: dx / length, y: dy / length)
        let path = NSBezierPath()

        path.lineWidth = lineWidth
        path.lineCapStyle = dashed ? .butt : .round
        path.lineJoinStyle = .round
        if dashed {
            path.setLineDash([3.4, 1.4], count: 2, phase: 0)
        }
        path.move(to: CGPoint(x: start.x + unit.x * inset, y: start.y + unit.y * inset))
        path.line(to: CGPoint(x: end.x - unit.x * inset, y: end.y - unit.y * inset))

        color.setStroke()
        path.stroke()
    }

    private static func drawNode(at point: CGPoint, fill: NSColor?) {
        if let fill {
            drawCircle(center: point, radius: nodeRadius, fill: fill, stroke: nil)
        }
        drawCircle(
            center: point,
            radius: nodeRadius,
            fill: nil,
            stroke: (color: NSColor.black.withAlphaComponent(0.82), width: nodeStroke)
        )
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

    private static func lineColor(for state: ConnectionGlyphState) -> NSColor {
        switch state {
        case .idle: return NSColor.black.withAlphaComponent(0.34)
        case .connected, .error: return NSColor.black.withAlphaComponent(0.72)
        case .connecting: return NSColor.black.withAlphaComponent(0.50)
        }
    }

    private static func statusColor(for state: ConnectionGlyphState) -> NSColor? {
        switch state {
        case .idle:
            nil
        case .connecting:
            .systemOrange
        case .connected:
            .systemGreen
        case .error:
            .systemRed
        }
    }
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
                .disabled(store.isBusy || store.isQuitting || store.selectedConfig == nil)
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

            if store.isQuitting {
                MenuBarPlainRow(title: "Quitting EasyTier...", isMuted: true)
                MenuBarDivider()
            }

            MenuBarListButton(title: "About EasyTier", isDisabled: store.isQuitting) {
                openMainWindow()
                store.isShowingAbout = true
                dismissMenuBar()
            }

            MenuBarListButton(title: "Install on Linux", isDisabled: store.isQuitting) {
                openMainWindow()
                store.isShowingLinuxInstallGuide = true
                dismissMenuBar()
            }

            MenuBarDivider()

            MenuBarListButton(title: windowEffectTitle, isDisabled: store.isQuitting) {
                appearanceSettings.glassEffectsEnabled.toggle()
            }

            MenuBarListButton(title: "Settings...", shortcut: "⌘ ,", isDisabled: store.isQuitting) {
                openMainWindow()
                store.isShowingSettings = true
                dismissMenuBar()
            }

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
        if store.lastError != nil { return .error }
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
        return firstNonEmpty(runtimeHostname, configHostname, Host.current().localizedName) ?? "This Mac"
    }

    private var deviceAddress: String {
        let node = store.selectedRuntimeDetail?.my_node_info
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
        if store.isQuitting { return "Quitting" }
        if store.isBusy { return "Working" }
        if store.lastError != nil { return "Needs Attention" }
        guard store.selectedConfig != nil else { return "No Network" }
        guard var instance = selectedRunningInstance else { return "Not Connected" }
        instance.detail = store.selectedRuntimeDetail
        return store.instanceIsFullyConnected(instance) ? "Connected" : "Connecting"
    }

    private var connectionIndicatorColor: Color {
        if store.isQuitting { return .yellow.opacity(0.82) }
        if store.lastError != nil { return .orange }
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
        guard var instance = selectedRunningInstance else { return "Disconnected" }
        instance.detail = store.selectedRuntimeDetail
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

extension View {
    @ViewBuilder
    func easyTierWindowBackground(glassEffectsEnabled: Bool) -> some View {
        if glassEffectsEnabled {
            containerBackground(for: .window) { FrostedGlass() }
        } else {
            containerBackground(Color(nsColor: .windowBackgroundColor), for: .window)
        }
    }

    func frostedGlassBackground<S: Shape>(in shape: S) -> some View {
        modifier(FrostedGlassBackground(shape: shape))
    }

    func liquidGlassMetricBackground<S: Shape>(in shape: S) -> some View {
        modifier(LiquidGlassMetricBackground(shape: shape))
    }
}

private struct FrostedGlassBackground<S: Shape>: ViewModifier {
    @Environment(AppAppearanceSettings.self) private var appearanceSettings

    var shape: S

    @ViewBuilder
    func body(content: Content) -> some View {
        if appearanceSettings.glassEffectsEnabled && !appearanceSettings.glassPanelBackgroundsEnabled {
            content
        } else {
            content.background {
                if appearanceSettings.glassEffectsEnabled {
                    FrostedGlass(blendingMode: .withinWindow)
                        .clipShape(shape)
                } else {
                    shape.fill(Color.primary.opacity(0.045))
                }
            }
        }
    }
}

private struct LiquidGlassMetricBackground<S: Shape>: ViewModifier {
    @Environment(AppAppearanceSettings.self) private var appearanceSettings
    @Environment(\.colorScheme) private var colorScheme

    var shape: S

    @ViewBuilder
    func body(content: Content) -> some View {
        content
            .background {
                shape.fill(backgroundColor)
            }
            .overlay {
                shape.stroke(strokeColor, lineWidth: 0.5)
            }
    }

    private var backgroundColor: Color {
        if appearanceSettings.glassEffectsEnabled {
            return Color.primary.opacity(colorScheme == .dark ? 0.038 : 0.052)
        }
        return Color.primary.opacity(colorScheme == .dark ? 0.052 : 0.075)
    }

    private var strokeColor: Color {
        if appearanceSettings.glassEffectsEnabled {
            return Color.primary.opacity(colorScheme == .dark ? 0.045 : 0.065)
        }
        return Color.primary.opacity(0.075)
    }
}

struct FrostedGlass: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        configure(view)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        configure(view)
    }

    private func configure(_ view: NSVisualEffectView) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.autoresizingMask = [.width, .height]
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
    var configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                configure(window)
            }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let window = view.window else { return }
        configure(window)
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
    var isDisabled = false
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
        .disabled(isDisabled)
        .onHover { isHovering = $0 }
        .animation(EasyTierMotion.quick(reduceMotion: reduceMotion), value: isHovering)
    }

    private var primaryTextColor: Color {
        if isDisabled { return MenuBarPalette.mutedText }
        return isHovering ? Color.white.opacity(0.96) : MenuBarPalette.primaryText
    }

    private var shortcutTextColor: Color {
        if isDisabled { return MenuBarPalette.mutedText.opacity(0.7) }
        return isHovering ? Color.white.opacity(0.72) : MenuBarPalette.mutedText
    }

    private var rowBackground: Color {
        if isDisabled { return .clear }
        return isHovering ? MenuBarPalette.selectedRow : .clear
    }
}
