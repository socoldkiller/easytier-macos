import AppKit
import EasyTierShared
import Foundation
import SwiftUI

@MainActor
final class MenuBarStatusItemController: NSObject {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let networkPopover = NSPopover()
    private let presentationState = MenuBarPresentationState()
    private var hostingController: NSHostingController<MenuBarRootView>?
    private var networkHostingController: NSHostingController<MenuBarNetworkPopoverRootView>?
    private weak var networkMenuAnchorView: NSView?
    private var isClosingNetworkPopover = false
    private var networkPopoverPresentationTask: Task<Void, Never>?
    private var networkPopoverDismissalTask: Task<Void, Never>?
    private var networkMenuHoverState = MenuBarNetworkMenuHoverState()
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

    private var preferredPopoverSize = NSSize(width: 300, height: 340)
    private var preferredNetworkPopoverSize = MenuBarPopoverLayout.networkSize(itemCount: 1)

    private static let counterclockwiseNodeIndexes = [0, 1, 2]
    private static let stepDuration: Duration = .milliseconds(340)
    private static let networkMenuDismissalDelay: Duration = .milliseconds(180)

    override init() {
        super.init()
        popover.delegate = self
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.contentSize = preferredPopoverSize
        networkPopover.delegate = self
        networkPopover.behavior = .applicationDefined
        networkPopover.animates = true
        networkPopover.contentSize = preferredNetworkPopoverSize
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
            networkPopover.animates = !reduceMotion
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
        closeNetworkPopover()
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
            popover.contentSize = preferredPopoverSize
            return
        }
        guard let appContext = currentAppContext else { return }

        let content = MenuBarRootView(
            appContext: appContext,
            presentationState: presentationState,
            openMainWindowAction: { [weak self] in self?.openMainWindowAction?() },
            quitApplicationAction: { [weak self] in self?.quitApplicationAction?() },
            dismissMenuBarAction: { [weak self] in self?.closePopover() },
            networkMenuAnchorAvailabilityDidChange: { [weak self] view, available in
                self?.networkMenuAnchorAvailabilityDidChange(view, available: available)
            },
            networkMenuPresentationDidChange: { [weak self] presented in
                self?.networkMenuPresentationDidChange(presented)
            },
            networkMenuTriggerHoverDidChange: { [weak self] hovering in
                self?.networkMenuHoverDidChange(hovering, in: .trigger)
            },
            preferredSizeDidChange: { [weak self] size in self?.updatePopoverSize(size) }
        )

        let controller = NSHostingController(rootView: content)
        controller.view.frame = NSRect(origin: .zero, size: preferredPopoverSize)
        hostingController = controller
        popover.contentViewController = controller
        popover.contentSize = preferredPopoverSize
    }

    private func updatePopoverSize(_ requestedSize: NSSize) {
        let size = MenuBarPopoverLayout.primarySize(for: requestedSize)
        guard size != preferredPopoverSize else { return }
        preferredPopoverSize = size
        hostingController?.view.frame.size = size
        popover.contentSize = size
    }

    private func networkMenuAnchorAvailabilityDidChange(_ view: NSView, available: Bool) {
        if available {
            networkMenuAnchorView = view
            if presentationState.isNetworkMenuPresented {
                scheduleNetworkPopoverPresentation()
            }
            return
        }
        guard networkMenuAnchorView === view else { return }
        networkMenuAnchorView = nil
        closeNetworkPopover()
    }

    private func networkMenuPresentationDidChange(_ presented: Bool) {
        if presented {
            scheduleNetworkPopoverPresentation()
        } else {
            closeNetworkPopover()
        }
    }

    private func showNetworkPopover() {
        guard !networkPopover.isShown else { return }
        guard popover.isShown else {
            presentationState.isNetworkMenuPresented = false
            return
        }
        guard let anchorView = networkMenuAnchorView,
              anchorView.window === popover.contentViewController?.view.window
        else { return }

        if let appContext = currentAppContext {
            let itemCount = NetworkPresentationResolver.items(for: appContext.workspace.store).count
            preferredNetworkPopoverSize = MenuBarPopoverLayout.networkSize(itemCount: itemCount)
        }
        installNetworkPopoverContentIfNeeded()
        networkPopover.show(
            relativeTo: anchorView.bounds,
            of: anchorView,
            preferredEdge: MenuBarPopoverLayout.networkPreferredEdge
        )
    }

    private func installNetworkPopoverContentIfNeeded() {
        guard networkHostingController == nil else {
            networkPopover.contentSize = preferredNetworkPopoverSize
            return
        }
        guard let appContext = currentAppContext else { return }

        let content = MenuBarNetworkPopoverRootView(
            appContext: appContext,
            dismissAction: { [weak self] in self?.closeNetworkPopover() },
            hoverDidChange: { [weak self] hovering in
                self?.networkMenuHoverDidChange(hovering, in: .popover)
            },
            preferredSizeDidChange: { [weak self] size in self?.updateNetworkPopoverSize(size) }
        )
        let controller = NSHostingController(rootView: content)
        controller.view.frame = NSRect(origin: .zero, size: preferredNetworkPopoverSize)
        networkHostingController = controller
        networkPopover.contentViewController = controller
        networkPopover.contentSize = preferredNetworkPopoverSize
    }

    private func updateNetworkPopoverSize(_ requestedSize: NSSize) {
        let maximumHeight = MenuBarPopoverLayout.networkSize(itemCount: 5).height
        let size = NSSize(
            width: MenuBarPopoverLayout.networkWidth,
            height: min(max(requestedSize.height, MenuBarPopoverLayout.networkHeaderHeight), maximumHeight)
        )
        guard size != preferredNetworkPopoverSize else { return }
        preferredNetworkPopoverSize = size
        networkHostingController?.view.frame.size = size
        networkPopover.contentSize = size
    }

    private func closeNetworkPopover() {
        networkPopoverPresentationTask?.cancel()
        networkPopoverPresentationTask = nil
        networkPopoverDismissalTask?.cancel()
        networkPopoverDismissalTask = nil
        networkMenuHoverState.reset()
        presentationState.isNetworkMenuPresented = false
        guard !isClosingNetworkPopover else { return }
        guard networkPopover.isShown else {
            resetNetworkPopoverContent()
            return
        }

        isClosingNetworkPopover = true
        networkPopover.performClose(nil)
    }

    private func resetNetworkPopoverContent() {
        networkPopover.contentViewController = nil
        networkHostingController = nil
        preferredNetworkPopoverSize = MenuBarPopoverLayout.networkSize(itemCount: 1)
        networkPopover.contentSize = preferredNetworkPopoverSize
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

    private func scheduleNetworkPopoverPresentation() {
        networkPopoverPresentationTask?.cancel()
        networkPopoverPresentationTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled,
                  let self,
                  self.presentationState.isNetworkMenuPresented
            else { return }
            self.showNetworkPopover()
            self.networkPopoverPresentationTask = nil
        }
    }

    private func networkMenuHoverDidChange(
        _ hovering: Bool,
        in region: MenuBarNetworkMenuHoverState.Region
    ) {
        networkMenuHoverState.setHovering(hovering, in: region)
        networkPopoverDismissalTask?.cancel()
        networkPopoverDismissalTask = nil
        guard !networkMenuHoverState.shouldRemainPresented else { return }

        networkPopoverDismissalTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.networkMenuDismissalDelay)
            } catch {
                return
            }
            guard let self, !self.networkMenuHoverState.shouldRemainPresented else { return }
            self.closeNetworkPopover()
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

        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            if event.type == .keyDown, event.keyCode == 53 {
                self?.closePopover()
                return nil
            }
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
        let primaryWindow = popover.contentViewController?.view.window
        let networkWindow = networkPopover.contentViewController?.view.window
        return event.window === primaryWindow || event.window === networkWindow
    }

    private func eventIsInsideStatusItem(_ event: NSEvent) -> Bool {
        guard let button = statusItem?.button, event.window === button.window else { return false }
        let point = button.convert(event.locationInWindow, from: nil)
        return button.bounds.contains(point)
    }

    deinit {
        animationTask?.cancel()
        networkPopoverPresentationTask?.cancel()
        networkPopoverDismissalTask?.cancel()
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
        if let closedPopover = notification.object as? NSPopover,
           closedPopover === networkPopover {
            isClosingNetworkPopover = false
            presentationState.isNetworkMenuPresented = false
            resetNetworkPopoverContent()
            return
        }

        closeNetworkPopover()
        removeDismissHandlers()
        popover.contentViewController = nil
        hostingController = nil
        networkMenuAnchorView = nil
        presentationState.isNetworkMenuPresented = false
        preferredPopoverSize = NSSize(width: 300, height: 340)
        popover.contentSize = preferredPopoverSize
    }
}
