import AppKit
import EasyTierShared

@MainActor
protocol NetworkSecretWindowPresentationTarget: AnyObject {
    var easyTierWindowRole: EasyTierWindowRole? { get }
    var isVisible: Bool { get }
    var isMiniaturized: Bool { get }
    var isKeyWindow: Bool { get }
    var isMainWindow: Bool { get }
    var authenticationSheetParent: (any NetworkSecretWindowPresentationTarget)? { get }
}

extension NSWindow: NetworkSecretWindowPresentationTarget {
    var easyTierWindowRole: EasyTierWindowRole? {
        EasyTierWindowRole(identifier: identifier)
    }

    var authenticationSheetParent: (any NetworkSecretWindowPresentationTarget)? {
        sheetParent
    }
}

@MainActor
protocol NetworkSecretApplicationPresenting: AnyObject {
    var isActive: Bool { get }
    var isHidden: Bool { get }
    var keyWindow: (any NetworkSecretWindowPresentationTarget)? { get }
    var windows: [any NetworkSecretWindowPresentationTarget] { get }

    func restoreWindow(_ window: any NetworkSecretWindowPresentationTarget)
}

@MainActor
final class SystemNetworkSecretApplicationPresenter: NetworkSecretApplicationPresenting {
    private let application: NSApplication

    init(application: NSApplication = .shared) {
        self.application = application
    }

    var isActive: Bool { application.isActive }
    var isHidden: Bool { application.isHidden }
    var keyWindow: (any NetworkSecretWindowPresentationTarget)? { application.keyWindow }
    var windows: [any NetworkSecretWindowPresentationTarget] { application.windows }

    func restoreWindow(_ target: any NetworkSecretWindowPresentationTarget) {
        guard let window = target as? NSWindow else { return }
        application.unhide(nil)
        window.orderFrontRegardless()
        application.activate(ignoringOtherApps: true)

        if let sheet = window.attachedSheet, sheet.isVisible {
            sheet.makeKeyAndOrderFront(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

@MainActor
final class NetworkSecretAuthenticationPresentationCoordinator: NetworkSecretAuthenticationActivityObserver {
    private let applicationPresenter: any NetworkSecretApplicationPresenting
    private var activeAuthenticationIDs: Set<UUID> = []
    private weak var windowToRestore: (any NetworkSecretWindowPresentationTarget)?
    private var capturedForegroundInteraction = false

    init() {
        applicationPresenter = SystemNetworkSecretApplicationPresenter()
    }

    init(applicationPresenter: any NetworkSecretApplicationPresenting) {
        self.applicationPresenter = applicationPresenter
    }

    func networkSecretAuthenticationDidBegin(id: UUID) {
        guard activeAuthenticationIDs.insert(id).inserted,
              !capturedForegroundInteraction,
              applicationPresenter.isActive,
              !applicationPresenter.isHidden,
              let mainWindow = mainWindow,
              mainWindow.isVisible,
              !mainWindow.isMiniaturized,
              Self.hostsInteraction(mainWindow, keyWindow: applicationPresenter.keyWindow)
        else { return }

        capturedForegroundInteraction = true
        windowToRestore = mainWindow
    }

    func networkSecretAuthenticationDidEnd(id: UUID) {
        guard activeAuthenticationIDs.remove(id) != nil,
              activeAuthenticationIDs.isEmpty
        else { return }

        defer {
            capturedForegroundInteraction = false
            windowToRestore = nil
        }

        guard capturedForegroundInteraction,
              !applicationPresenter.isHidden,
              let windowToRestore,
              windowToRestore.isVisible,
              !windowToRestore.isMiniaturized,
              !applicationPresenter.isActive
                || !Self.hostsInteraction(
                    windowToRestore,
                    keyWindow: applicationPresenter.keyWindow
                )
        else { return }

        applicationPresenter.restoreWindow(windowToRestore)
    }

    private var mainWindow: (any NetworkSecretWindowPresentationTarget)? {
        applicationPresenter.windows.first {
            $0.easyTierWindowRole == .main
        }
    }

    private static func hostsInteraction(
        _ mainWindow: any NetworkSecretWindowPresentationTarget,
        keyWindow: (any NetworkSecretWindowPresentationTarget)?
    ) -> Bool {
        var candidate = keyWindow
        while let window = candidate {
            if window === mainWindow { return true }
            candidate = window.authenticationSheetParent
        }
        return mainWindow.isKeyWindow || mainWindow.isMainWindow
    }
}
