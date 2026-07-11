import AppKit
import Foundation

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
