import AppKit
import EasyTierShared
import SwiftUI

@MainActor
struct MenuBarStatusItemBridge: NSViewRepresentable {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let appContext: AppContext
    var connectionState: ConnectionGlyphState
    let quitApplicationAction: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        updateController()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        updateController()
    }

    private func updateController() {
        appContext.presentation.menuBarController.update(
            appContext: appContext,
            connectionState: connectionState,
            reduceMotion: reduceMotion,
            openMainWindow: openMainWindow,
            quitApplication: quitApplicationAction
        )
    }

    private func openMainWindow() {
        NSApplication.shared.unhide(nil)
        openWindow(id: EasyTierWindowID.main)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
