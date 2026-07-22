import AppKit
import EasyTierShared
import SwiftUI

enum GlassSurfaceRole: CaseIterable {
    case windowBackdrop
    case sidebar
    case panel
    case sheet
    case popover

    func configuration(reduceTransparency: Bool) -> GlassVisualEffectConfiguration {
        let material: NSVisualEffectView.Material
        let blendingMode: NSVisualEffectView.BlendingMode

        switch self {
        case .windowBackdrop:
            material = .underWindowBackground
            blendingMode = .behindWindow
        case .sidebar:
            material = .sidebar
            blendingMode = .behindWindow
        case .panel:
            material = .sidebar
            blendingMode = .withinWindow
        case .sheet:
            material = .sheet
            blendingMode = .behindWindow
        case .popover:
            material = .popover
            blendingMode = .behindWindow
        }

        return GlassVisualEffectConfiguration(
            material: material,
            blendingMode: blendingMode,
            state: .followsWindowActiveState,
            isEnabled: !reduceTransparency
        )
    }
}

struct GlassVisualEffectConfiguration: Equatable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    var state: NSVisualEffectView.State
    var isEnabled: Bool
}

enum WindowRenderEligibility {
    static func evaluate(
        screenAvailable: Bool,
        sessionActive: Bool,
        windowAttached: Bool,
        windowVisible: Bool,
        windowMiniaturized: Bool,
        windowOcclusionVisible: Bool
    ) -> Bool {
        screenAvailable
            && sessionActive
            && windowAttached
            && windowVisible
            && !windowMiniaturized
            && windowOcclusionVisible
    }
}

enum WindowPresentationActivityResolver {
    static func evaluate(
        renderEligible: Bool,
        applicationActive: Bool,
        windowKey: Bool
    ) -> RuntimePresentationActivity {
        guard renderEligible else { return .suspended }
        return applicationActive && windowKey ? .interactive : .visibleInactive
    }
}

@MainActor
final class GlassRenderCoordinator {
    private let hosts = NSHashTable<ManagedVisualEffectHostView>.weakObjects()
    private var notificationTasks: [Task<Void, Never>] = []
    private(set) var screenAvailable = true
    private(set) var sessionActive = true

    init() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        notificationTasks = [
            notificationTask(center: workspaceCenter, name: NSWorkspace.screensDidSleepNotification) { coordinator in
                coordinator.setScreenAvailable(false)
            },
            notificationTask(center: workspaceCenter, name: NSWorkspace.screensDidWakeNotification) { coordinator in
                coordinator.setScreenAvailable(true)
            },
            notificationTask(center: workspaceCenter, name: NSWorkspace.willSleepNotification) { coordinator in
                coordinator.setScreenAvailable(false)
            },
            notificationTask(center: workspaceCenter, name: NSWorkspace.didWakeNotification) { coordinator in
                coordinator.setScreenAvailable(true)
            },
            notificationTask(center: workspaceCenter, name: NSWorkspace.sessionDidResignActiveNotification) { coordinator in
                coordinator.setSessionActive(false)
            },
            notificationTask(center: workspaceCenter, name: NSWorkspace.sessionDidBecomeActiveNotification) { coordinator in
                coordinator.setSessionActive(true)
            },
        ]
    }

    func register(_ host: ManagedVisualEffectHostView) {
        hosts.add(host)
        host.globalRenderingAvailabilityDidChange(
            screenAvailable: screenAvailable,
            sessionActive: sessionActive
        )
    }

    func unregister(_ host: ManagedVisualEffectHostView) {
        hosts.remove(host)
    }

    private func setScreenAvailable(_ available: Bool) {
        guard screenAvailable != available else { return }
        screenAvailable = available
        notifyHosts()
    }

    private func setSessionActive(_ active: Bool) {
        guard sessionActive != active else { return }
        sessionActive = active
        notifyHosts()
    }

    private func notifyHosts() {
        for host in hosts.allObjects {
            host.globalRenderingAvailabilityDidChange(
                screenAvailable: screenAvailable,
                sessionActive: sessionActive
            )
        }
    }

    private func notificationTask(
        center: NotificationCenter,
        name: Notification.Name,
        action: @escaping @MainActor (GlassRenderCoordinator) -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            let notifications = center.notifications(named: name)
            for await _ in notifications {
                guard !Task.isCancelled, let self else { break }
                action(self)
            }
        }
    }
}

@MainActor
final class ManagedVisualEffectHostView: NSView {
    private(set) var effectView: NSVisualEffectView?
    private(set) var configurationApplyCount = 0

    private var configuration: GlassVisualEffectConfiguration?
    private weak var renderCoordinator: GlassRenderCoordinator?
    private var isRenderingEligible = false
    private var screenAvailable = true
    private var sessionActive = true
    nonisolated(unsafe) private var windowObservers: [NSObjectProtocol] = []

    override var isOpaque: Bool {
        configuration?.isEnabled == false
    }

    override func draw(_ dirtyRect: NSRect) {
        guard configuration?.isEnabled == false else { return }
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }

    @discardableResult
    func apply(configuration: GlassVisualEffectConfiguration) -> Bool {
        guard self.configuration != configuration else { return false }
        self.configuration = configuration
        configurationApplyCount += 1
        needsDisplay = true
        updateEffectChild()
        return true
    }

    func reconcileRendering(isEligible: Bool) {
        guard isRenderingEligible != isEligible else { return }
        isRenderingEligible = isEligible
        updateEffectChild()
    }

    func globalRenderingAvailabilityDidChange(screenAvailable: Bool, sessionActive: Bool) {
        self.screenAvailable = screenAvailable
        self.sessionActive = sessionActive
        reconcileWindowRendering()
    }

    func setRenderCoordinator(_ coordinator: GlassRenderCoordinator) {
        guard renderCoordinator !== coordinator else { return }
        renderCoordinator?.unregister(self)
        renderCoordinator = coordinator
        if window != nil {
            coordinator.register(self)
        }
    }

    func tearDown() {
        removeWindowObservers()
        renderCoordinator?.unregister(self)
        reconcileRendering(isEligible: false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            reconcileRendering(isEligible: false)
            return
        }
        installWindowObservers(for: window)
        renderCoordinator?.register(self)
        reconcileWindowRendering()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window {
            removeWindowObservers()
            renderCoordinator?.unregister(self)
            reconcileRendering(isEligible: false)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    private func updateEffectChild() {
        guard isRenderingEligible, let configuration, configuration.isEnabled else {
            removeEffectChild()
            return
        }

        let effectView: NSVisualEffectView
        if let existing = self.effectView {
            effectView = existing
        } else {
            let created = NSVisualEffectView(frame: bounds)
            created.autoresizingMask = [.width, .height]
            addSubview(created)
            self.effectView = created
            effectView = created
        }
        if apply(configuration, to: effectView) {
            EasyTierPerformanceSignposts.glassConfigurationChanged()
        }
    }

    @discardableResult
    private func apply(_ configuration: GlassVisualEffectConfiguration, to effectView: NSVisualEffectView) -> Bool {
        var changed = false
        if effectView.material != configuration.material {
            effectView.material = configuration.material
            changed = true
        }
        if effectView.blendingMode != configuration.blendingMode {
            effectView.blendingMode = configuration.blendingMode
            changed = true
        }
        if effectView.state != configuration.state {
            effectView.state = configuration.state
            changed = true
        }
        return changed
    }

    private func removeEffectChild() {
        guard let effectView else { return }
        effectView.state = .inactive
        effectView.removeFromSuperview()
        self.effectView = nil
    }

    private func reconcileWindowRendering() {
        guard let window else {
            reconcileRendering(isEligible: false)
            return
        }
        reconcileRendering(isEligible: WindowRenderEligibility.evaluate(
            screenAvailable: screenAvailable,
            sessionActive: sessionActive,
            windowAttached: true,
            windowVisible: window.isVisible,
            windowMiniaturized: window.isMiniaturized,
            windowOcclusionVisible: window.occlusionState.contains(.visible)
        ))
    }

    private func installWindowObservers(for window: NSWindow) {
        removeWindowObservers()
        let names: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
        ]
        windowObservers = names.map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.reconcileWindowRendering()
                }
            }
        }
    }

    private func removeWindowObservers() {
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers = []
    }

    deinit {
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

enum EasyTierWindowRole: String, CaseIterable {
    case main
    case settings

    var identifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier(rawValue)
    }

    init?(identifier: NSUserInterfaceItemIdentifier?) {
        guard let identifier else { return nil }
        self.init(rawValue: identifier.rawValue)
    }
}

enum EasyTierWindowConfigurator {
    @MainActor
    @discardableResult
    static func configureIfOwned(_ window: NSWindow, effectiveGlass: Bool) -> Bool {
        guard EasyTierWindowRole(identifier: window.identifier) != nil else { return false }
        configure(window, effectiveGlass: effectiveGlass)
        return true
    }

    @MainActor
    static func configure(_ window: NSWindow, role: EasyTierWindowRole, effectiveGlass: Bool) {
        window.identifier = role.identifier
        configure(window, effectiveGlass: effectiveGlass)
    }

    @MainActor
    private static func configure(_ window: NSWindow, effectiveGlass: Bool) {
        let frame = window.frame
        window.hidesOnDeactivate = false
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
        if !window.titlebarAppearsTransparent {
            window.titlebarAppearsTransparent = true
        }

        let targetOpacity = !effectiveGlass
        if window.isOpaque != targetOpacity {
            window.isOpaque = targetOpacity
        }

        let targetBackgroundColor: NSColor = effectiveGlass ? .clear : .windowBackgroundColor
        if window.backgroundColor != targetBackgroundColor {
            window.backgroundColor = targetBackgroundColor
        }

        if window.frame != frame {
            window.setFrame(frame, display: true)
        }
    }
}

extension View {
    @ViewBuilder
    func easyTierWindowBackground(
        glassEffectsEnabled: Bool,
        renderCoordinator: GlassRenderCoordinator
    ) -> some View {
        if glassEffectsEnabled {
            containerBackground(for: .window) {
                FrostedGlass(
                    role: .windowBackdrop,
                    renderCoordinator: renderCoordinator
                )
            }
        } else {
            containerBackground(Color(nsColor: .windowBackgroundColor), for: .window)
        }
    }

    func easyTierSidebarBackground(
        glassEffectsEnabled: Bool,
        renderCoordinator: GlassRenderCoordinator
    ) -> some View {
        background {
            if glassEffectsEnabled {
                FrostedGlass(
                    role: .sidebar,
                    renderCoordinator: renderCoordinator
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)
            } else {
                Color(nsColor: .windowBackgroundColor)
                    .ignoresSafeArea()
            }
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
    @Environment(AppContext.self) private var appContext
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var shape: S

    private var appearanceSettings: AppAppearanceSettings { appContext.settings.appearance }
    private var glassEnabled: Bool {
        appearanceSettings.glassEffectsEnabled && !reduceTransparency
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if glassEnabled && !appearanceSettings.glassPanelBackgroundsEnabled {
            content
        } else {
            content.background {
                if glassEnabled {
                    FrostedGlass(
                        role: .panel,
                        renderCoordinator: appContext.presentation.glassRenderCoordinator
                    )
                        .clipShape(shape)
                } else {
                    shape.fill(Color.primary.opacity(0.045))
                }
            }
        }
    }
}

private struct LiquidGlassMetricBackground<S: Shape>: ViewModifier {
    @Environment(AppContext.self) private var appContext
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var shape: S

    private var appearanceSettings: AppAppearanceSettings { appContext.settings.appearance }
    private var glassEnabled: Bool {
        appearanceSettings.glassEffectsEnabled && !reduceTransparency
    }

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
        if glassEnabled {
            return Color.primary.opacity(colorScheme == .dark ? 0.038 : 0.052)
        }
        return Color.primary.opacity(colorScheme == .dark ? 0.052 : 0.075)
    }

    private var strokeColor: Color {
        if glassEnabled {
            return Color.primary.opacity(colorScheme == .dark ? 0.045 : 0.065)
        }
        return Color.primary.opacity(0.075)
    }
}

struct FrostedGlass: NSViewRepresentable {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var role: GlassSurfaceRole
    var renderCoordinator: GlassRenderCoordinator

    func makeNSView(context: Context) -> ManagedVisualEffectHostView {
        let view = ManagedVisualEffectHostView()
        view.setRenderCoordinator(renderCoordinator)
        // Seed the first frame before AppKit orders a new window on screen.
        view.reconcileRendering(isEligible: true)
        view.apply(configuration: role.configuration(reduceTransparency: reduceTransparency))
        return view
    }

    func updateNSView(_ view: ManagedVisualEffectHostView, context: Context) {
        view.setRenderCoordinator(renderCoordinator)
        view.apply(configuration: role.configuration(reduceTransparency: reduceTransparency))
    }

    static func dismantleNSView(_ view: ManagedVisualEffectHostView, coordinator: ()) {
        view.tearDown()
    }
}

struct GlassFieldStyle: TextFieldStyle {
    @Environment(\.accessibilityShowButtonShapes) private var showButtonShapes

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
                    .strokeBorder(
                        .primary.opacity(showButtonShapes ? 0.35 : 0.1),
                        lineWidth: showButtonShapes ? 1 : 0.5
                    )
            }
    }
}

extension TextFieldStyle where Self == GlassFieldStyle {
    static var glassField: GlassFieldStyle { .init() }
}

private struct WindowPresentationActivityKey: EnvironmentKey {
    static let defaultValue: RuntimePresentationActivity = .interactive
}

extension EnvironmentValues {
    var windowPresentationActivity: RuntimePresentationActivity {
        get { self[WindowPresentationActivityKey.self] }
        set { self[WindowPresentationActivityKey.self] = newValue }
    }
}

struct WindowAccessor: NSViewRepresentable {
    var role: EasyTierWindowRole
    var glassEffectsEnabled: Bool
    var activityDidChange: ((RuntimePresentationActivity) -> Void)?

    func makeNSView(context: Context) -> WindowAccessorView {
        let view = WindowAccessorView()
        update(view)
        return view
    }

    func updateNSView(_ view: WindowAccessorView, context: Context) {
        update(view)
    }

    static func dismantleNSView(_ view: WindowAccessorView, coordinator: ()) {
        view.stopObserving()
    }

    private func update(_ view: WindowAccessorView) {
        view.role = role
        view.glassEffectsEnabled = glassEffectsEnabled
        view.activityDidChange = activityDidChange
        view.applyCurrentWindowState()
    }
}

@MainActor
final class WindowAccessorView: NSView {
    var role: EasyTierWindowRole = .main
    var glassEffectsEnabled = false
    var activityDidChange: ((RuntimePresentationActivity) -> Void)?

    private var lastActivity: RuntimePresentationActivity?
    private var hasPresentedVisibleActivity = false
    private var screenAvailable = true
    private var sessionActive = true
    nonisolated(unsafe) private var windowObservers: [NSObjectProtocol] = []
    private var notificationTasks: [Task<Void, Never>] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        installWindowObservers(for: window)
        installGlobalObserversIfNeeded()
        applyCurrentWindowState()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window {
            removeWindowObservers()
            if hasPresentedVisibleActivity {
                reportActivity(.suspended)
            }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    func applyCurrentWindowState() {
        guard let window else {
            if hasPresentedVisibleActivity {
                reportActivity(.suspended)
            }
            return
        }
        let effectiveGlass = glassEffectsEnabled
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        EasyTierWindowConfigurator.configure(window, role: role, effectiveGlass: effectiveGlass)
        reportCurrentActivity(for: window)
    }

    func stopObserving() {
        removeWindowObservers()
        for task in notificationTasks {
            task.cancel()
        }
        notificationTasks = []
        if hasPresentedVisibleActivity {
            reportActivity(.suspended)
            hasPresentedVisibleActivity = false
        }
    }

    private func reportCurrentActivity(for window: NSWindow) {
        let renderable = WindowRenderEligibility.evaluate(
            screenAvailable: screenAvailable,
            sessionActive: sessionActive,
            windowAttached: true,
            windowVisible: window.isVisible,
            windowMiniaturized: window.isMiniaturized,
            windowOcclusionVisible: window.occlusionState.contains(.visible)
        )

        let activity = WindowPresentationActivityResolver.evaluate(
            renderEligible: renderable,
            applicationActive: NSApplication.shared.isActive,
            windowKey: window.isKeyWindow
        )
        guard activity != .suspended || hasPresentedVisibleActivity else { return }
        if activity != .suspended {
            hasPresentedVisibleActivity = true
        }
        reportActivity(activity)
    }

    private func reportActivity(_ activity: RuntimePresentationActivity) {
        guard lastActivity != activity else { return }
        lastActivity = activity
        activityDidChange?(activity)
    }

    private func installWindowObservers(for window: NSWindow) {
        removeWindowObservers()
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
        ]
        windowObservers = names.map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.applyCurrentWindowState()
                }
            }
        }
    }

    private func installGlobalObserversIfNeeded() {
        guard notificationTasks.isEmpty else { return }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        notificationTasks = [
            notificationTask(center: NotificationCenter.default, name: NSApplication.didBecomeActiveNotification) { view in
                view.applyCurrentWindowState()
            },
            notificationTask(center: NotificationCenter.default, name: NSApplication.didResignActiveNotification) { view in
                view.applyCurrentWindowState()
            },
            notificationTask(center: workspaceCenter, name: NSWorkspace.screensDidSleepNotification) { view in
                view.screenAvailable = false
                view.applyCurrentWindowState()
            },
            notificationTask(center: workspaceCenter, name: NSWorkspace.screensDidWakeNotification) { view in
                view.screenAvailable = true
                view.applyCurrentWindowState()
            },
            notificationTask(center: workspaceCenter, name: NSWorkspace.willSleepNotification) { view in
                view.screenAvailable = false
                view.applyCurrentWindowState()
            },
            notificationTask(center: workspaceCenter, name: NSWorkspace.didWakeNotification) { view in
                view.screenAvailable = true
                view.applyCurrentWindowState()
            },
            notificationTask(center: workspaceCenter, name: NSWorkspace.sessionDidResignActiveNotification) { view in
                view.sessionActive = false
                view.applyCurrentWindowState()
            },
            notificationTask(center: workspaceCenter, name: NSWorkspace.sessionDidBecomeActiveNotification) { view in
                view.sessionActive = true
                view.applyCurrentWindowState()
            },
            notificationTask(center: workspaceCenter, name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { view in
                view.applyCurrentWindowState()
            },
        ]
    }

    private func notificationTask(
        center: NotificationCenter,
        name: Notification.Name,
        action: @escaping @MainActor (WindowAccessorView) -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            let notifications = center.notifications(named: name)
            for await _ in notifications {
                guard !Task.isCancelled, let self else { break }
                action(self)
            }
        }
    }

    private func removeWindowObservers() {
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers = []
    }

    deinit {
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        for task in notificationTasks {
            task.cancel()
        }
    }
}
