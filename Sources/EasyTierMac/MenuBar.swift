import EasyTierShared
import AppKit
import Foundation
import SwiftUI

struct MenuBarStatusItemBridge: NSViewRepresentable {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            reduceMotion: reduceMotion,
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
            reduceMotion: reduceMotion,
            openMainWindow: openMainWindow
        )
    }

    private func openMainWindow() {
        NSApp.unhide(nil)
        openWindow(id: EasyTierWindowID.main)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class MenuBarStatusItemController: NSObject {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var hostingController: NSHostingController<AnyView>?
    private var connectionState: ConnectionGlyphState = .idle
    private var activeNodeIndex = 0
    private var animationTask: Task<Void, Never>?
    nonisolated(unsafe) private var localEventMonitor: Any?
    nonisolated(unsafe) private var globalEventMonitor: Any?
    private var resignActiveTask: Task<Void, Never>?
    private var renderAvailabilityTasks: [Task<Void, Never>] = []
    private var openMainWindowAction: (() -> Void)?
    private var currentStore: EasyTierAppStore?
    private var currentUpdater: SoftwareUpdateController?
    private var currentAppearanceSettings: AppAppearanceSettings?
    private var reduceMotion = false
    private var screenAvailable = true
    private var sessionActive = true

    private static let popoverSize = NSSize(width: 292, height: 370)
    private static let counterclockwiseNodeIndexes = [0, 1, 2]
    private static let stepDurationNanoseconds: UInt64 = 340_000_000

    override init() {
        super.init()
        popover.delegate = self
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = Self.popoverSize
        installRenderAvailabilityObservers()
    }

    func update(
        store: EasyTierAppStore,
        updater: SoftwareUpdateController,
        appearanceSettings: AppAppearanceSettings,
        connectionState: ConnectionGlyphState,
        reduceMotion: Bool,
        openMainWindow: @escaping () -> Void
    ) {
        installStatusItemIfNeeded()
        openMainWindowAction = openMainWindow
        currentStore = store
        currentUpdater = updater
        currentAppearanceSettings = appearanceSettings

        if self.reduceMotion != reduceMotion {
            self.reduceMotion = reduceMotion
            popover.animates = !reduceMotion
            activeNodeIndex = 0
            updateAnimation()
        }

        if self.connectionState != connectionState {
            self.connectionState = connectionState
            activeNodeIndex = 0
            updateAnimation()
        }
        refreshStatusImage()
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

    private func installPopoverContentIfNeeded() {
        guard hostingController == nil else {
            popover.contentSize = Self.popoverSize
            return
        }
        guard let store = currentStore,
              let updater = currentUpdater,
              let appearanceSettings = currentAppearanceSettings
        else { return }

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
        if connectionState == .connecting, !reduceMotion, screenAvailable, sessionActive {
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
        animationTask = nil

        guard connectionState == .connecting, !reduceMotion, screenAvailable, sessionActive else {
            activeNodeIndex = 0
            refreshStatusImage()
            return
        }
        animationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: Self.stepDurationNanoseconds)
                } catch {
                    break
                }
                guard let self else { break }
                self.activeNodeIndex = (self.activeNodeIndex + 1) % Self.counterclockwiseNodeIndexes.count
                self.refreshStatusImage()
            }
        }
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let button = statusItem?.button else { return }

        if popover.isShown {
            closePopover()
        } else {
            NSApp.activate(ignoringOtherApps: true)
            installPopoverContentIfNeeded()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            installDismissHandlers()
        }
    }

    private func installRenderAvailabilityObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        renderAvailabilityTasks = [
            renderAvailabilityTask(center: workspaceCenter, name: NSWorkspace.screensDidSleepNotification) { controller in
                controller.setScreenAvailable(false)
            },
            renderAvailabilityTask(center: workspaceCenter, name: NSWorkspace.screensDidWakeNotification) { controller in
                controller.setScreenAvailable(true)
            },
            renderAvailabilityTask(center: workspaceCenter, name: NSWorkspace.willSleepNotification) { controller in
                controller.setScreenAvailable(false)
            },
            renderAvailabilityTask(center: workspaceCenter, name: NSWorkspace.didWakeNotification) { controller in
                controller.setScreenAvailable(true)
            },
            renderAvailabilityTask(center: workspaceCenter, name: NSWorkspace.sessionDidResignActiveNotification) { controller in
                controller.setSessionActive(false)
            },
            renderAvailabilityTask(center: workspaceCenter, name: NSWorkspace.sessionDidBecomeActiveNotification) { controller in
                controller.setSessionActive(true)
            },
        ]
    }

    private func renderAvailabilityTask(
        center: NotificationCenter,
        name: Notification.Name,
        action: @escaping @MainActor (MenuBarStatusItemController) -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            let notifications = center.notifications(named: name)
            for await _ in notifications {
                guard !Task.isCancelled, let self else { break }
                action(self)
            }
        }
    }

    private func setScreenAvailable(_ available: Bool) {
        guard screenAvailable != available else { return }
        screenAvailable = available
        updateAnimation()
    }

    private func setSessionActive(_ active: Bool) {
        guard sessionActive != active else { return }
        sessionActive = active
        updateAnimation()
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

        resignActiveTask = Task { @MainActor [weak self] in
            let notifications = NotificationCenter.default.notifications(
                named: NSApplication.didResignActiveNotification,
                object: NSApp
            )
            for await _ in notifications {
                guard !Task.isCancelled else { break }
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
        resignActiveTask?.cancel()
        resignActiveTask = nil
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

    deinit {
        animationTask?.cancel()
        resignActiveTask?.cancel()
        for task in renderAvailabilityTasks {
            task.cancel()
        }
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
        }
    }
}

extension MenuBarStatusItemController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        removeDismissHandlers()
        popover.contentViewController = nil
        hostingController = nil
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
