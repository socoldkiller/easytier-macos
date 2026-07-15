import AppKit
import Foundation

@MainActor
final class EasyTierApplicationDelegate: NSObject, NSApplicationDelegate {
    private static var quitPreparation: (() async -> Void)?
    private static var quitTask: Task<Void, Never>?

    static func installQuitPreparation(_ preparation: @escaping () async -> Void) {
        quitPreparation = preparation
    }

    static func hideToMenuBar() {
        NSApp.hide(nil)
    }

    static func quitEasyTier() {
        NSApp.terminate(nil)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard let application = notification.object as? NSApplication else { return }
        let showsDockIcon = AppAppearanceSettings.persistedShowsDockIcon()
        _ = application.setActivationPolicy(AppAppearanceSettings.activationPolicy(showsDockIcon: showsDockIcon))
    }

    func applicationShouldTerminate(_ application: NSApplication) -> NSApplication.TerminateReply {
        guard Self.quitTask == nil else { return .terminateLater }
        guard let quitPreparation = Self.quitPreparation else { return .terminateNow }

        Self.quitTask = Task {
            await quitPreparation()
            application.reply(toApplicationShouldTerminate: true)
            Self.quitTask = nil
        }
        return .terminateLater
    }
}
