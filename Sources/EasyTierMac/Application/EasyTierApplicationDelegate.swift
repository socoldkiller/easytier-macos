import AppKit
import Foundation

@MainActor
final class EasyTierApplicationDelegate: NSObject, NSApplicationDelegate {
    private var quitPreparation: (() async -> Void)?
    private var quitTask: Task<Void, Never>?
    private var didBecomeActive: (() -> Void)?
    private var didResignActive: (() -> Void)?
    private var didHide: (() -> Void)?

    func installQuitPreparation(_ preparation: @escaping () async -> Void) {
        quitPreparation = preparation
    }

    func installApplicationActivityHandlers(
        didBecomeActive: @escaping () -> Void,
        didResignActive: @escaping () -> Void,
        didHide: @escaping () -> Void
    ) {
        self.didBecomeActive = didBecomeActive
        self.didResignActive = didResignActive
        self.didHide = didHide
    }

    func quitEasyTier() {
        NSApplication.shared.terminate(nil)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard let application = notification.object as? NSApplication else { return }
        let showsDockIcon = AppAppearanceSettings.persistedShowsDockIcon()
        SystemDockIconVisibilityService(application: application)
            .applyDockIconVisibility(showsDockIcon)
    }

    func applicationDidBecomeActive(_: Notification) {
        didBecomeActive?()
    }

    func applicationDidResignActive(_: Notification) {
        didResignActive?()
    }

    func applicationDidHide(_: Notification) {
        didHide?()
    }

    func applicationShouldTerminate(_ application: NSApplication) -> NSApplication.TerminateReply {
        guard quitTask == nil else { return .terminateLater }
        guard let quitPreparation else { return .terminateNow }

        quitTask = Task { [weak self] in
            await quitPreparation()
            application.reply(toApplicationShouldTerminate: true)
            self?.quitTask = nil
        }
        return .terminateLater
    }
}
