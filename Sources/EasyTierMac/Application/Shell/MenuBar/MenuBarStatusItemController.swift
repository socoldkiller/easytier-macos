import AppKit
import EasyTierShared
import Foundation
import SwiftUI

@MainActor
final class MenuBarStatusItemController: NSObject {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var hostingController: NSHostingController<MenuBarRootView>?
    private var connectionState: ConnectionGlyphState = .idle
    private var activeNodeIndex = 0
    private var animationTask: Task<Void, Never>?
    nonisolated(unsafe) private var localEventMonitor: Any?
    nonisolated(unsafe) private var globalEventMonitor: Any?
    private var resignActiveTask: Task<Void, Never>?
    private var renderAvailabilityTasks: [Task<Void, Never>] = []
    private var openMainWindowAction: (() -> Void)?
    private var quitApplicationAction: (() -> Void)?
    private var currentAppContext: AppContext?
    private var reduceMotion = false
    private var screenAvailable = true
    private var sessionActive = true

    private static let popoverSize = NSSize(width: 280, height: 340)
    private static let counterclockwiseNodeIndexes = [0, 1, 2]
    private static let stepDuration: Duration = .milliseconds(340)

    override init() {
        super.init()
        popover.delegate = self
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = Self.popoverSize
        installRenderAvailabilityObservers()
    }

    func update(
        appContext: AppContext,
        connectionState: ConnectionGlyphState,
        reduceMotion: Bool,
        openMainWindow: @escaping () -> Void,
        quitApplication: @escaping () -> Void
    ) {
        installStatusItemIfNeeded()
        openMainWindowAction = openMainWindow
        quitApplicationAction = quitApplication
        currentAppContext = appContext

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
        guard let appContext = currentAppContext else { return }

        let content = MenuBarRootView(
            appContext: appContext,
            openMainWindowAction: { [weak self] in self?.openMainWindowAction?() },
            quitApplicationAction: { [weak self] in self?.quitApplicationAction?() },
            dismissMenuBarAction: { [weak self] in self?.closePopover() }
        )

        let controller = NSHostingController(rootView: content)
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
                    try await Task.sleep(for: Self.stepDuration)
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
            NSApplication.shared.activate(ignoringOtherApps: true)
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
                object: NSApplication.shared
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
