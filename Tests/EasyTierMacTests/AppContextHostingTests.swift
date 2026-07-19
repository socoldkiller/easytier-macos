import AppKit
import SwiftUI
import Testing
@testable import EasyTierMac

@MainActor
@Test func menuBarRootInjectsAppContextIntoItsIndependentHostingGraph() {
    let appContext = AppContext.preview()
    let rootView = MenuBarRootView(
        appContext: appContext,
        openMainWindowAction: {},
        quitApplicationAction: {},
        dismissMenuBarAction: {}
    )
    let hostingView = NSHostingView(rootView: rootView)

    hostingView.frame = NSRect(x: 0, y: 0, width: 292, height: 370)
    hostingView.layoutSubtreeIfNeeded()

    #expect(hostingView.fittingSize.width > 0)
    #expect(hostingView.fittingSize.height > 0)
}

@MainActor
@Test func settingsRootRendersWithAppContextEnvironment() {
    let appContext = AppContext.preview()
    let store = appContext.workspace.store
    let rootView = EasyTierSettingsSheet(
        initialTab: appContext.settings.requestedTab,
        mode: store.mode,
        magicDNSSettings: store.magicDNSSettings,
        onChange: { _, _ in }
    )
    .environment(appContext)
    let hostingView = NSHostingView(rootView: rootView)

    hostingView.frame = NSRect(x: 0, y: 0, width: 760, height: 620)
    hostingView.layoutSubtreeIfNeeded()

    #expect(hostingView.fittingSize.width > 0)
    #expect(hostingView.fittingSize.height > 0)
}

@MainActor
@Test func gatewaySettingsRendersWithAppContextEnvironment() {
    let appContext = AppContext.preview()
    let store = appContext.workspace.store
    let rootView = EasyTierSettingsSheet(
        initialTab: .gateway,
        mode: store.mode,
        magicDNSSettings: store.magicDNSSettings,
        onChange: { _, _ in }
    )
    .environment(appContext)
    let hostingView = NSHostingView(rootView: rootView)

    hostingView.frame = NSRect(x: 0, y: 0, width: 760, height: 620)
    hostingView.layoutSubtreeIfNeeded()

    #expect(hostingView.fittingSize.width > 0)
    #expect(hostingView.fittingSize.height > 0)
}
