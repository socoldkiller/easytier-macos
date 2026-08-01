import AppKit
import EasyTierShared
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
@Test(arguments: [EasyTierSettingsTab.account, .network, .advanced, .about])
func settingsPanesRenderWithAppContextEnvironment(tab: EasyTierSettingsTab) {
    let appContext = AppContext.preview()
    let store = appContext.workspace.store
    let rootView = EasyTierSettingsSheet(
        initialTab: tab,
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
@Test func aboutWindowRendersWithAppContextEnvironment() {
    let appContext = AppContext.preview()
    let rootView = EasyTierAboutView()
        .environment(appContext)
    let hostingView = NSHostingView(rootView: rootView)

    hostingView.frame = NSRect(x: 0, y: 0, width: 460, height: 520)
    hostingView.layoutSubtreeIfNeeded()

    #expect(hostingView.fittingSize.width > 0)
    #expect(hostingView.fittingSize.height > 0)
}

@MainActor
@Test func configServerManagedConfigurationRendersInReadOnlyEditor() {
    let appContext = AppContext.preview()
    let config = NetworkConfig(
        instance_id: "11111111-2222-3333-4444-555555555555",
        hostname: "managed-mac",
        network_name: "managed-network",
        peer_urls: ["tcp://peer.example.com:11010"],
        listener_urls: ["tcp://0.0.0.0:11010"],
        no_tun: true
    )
    let rootView = ConfigEditorView(config: .constant(config), isReadOnly: true)
        .environment(appContext)
    let hostingView = NSHostingView(rootView: rootView)

    hostingView.frame = NSRect(x: 0, y: 0, width: 820, height: 720)
    hostingView.layoutSubtreeIfNeeded()

    #expect(hostingView.fittingSize.width > 0)
    #expect(hostingView.fittingSize.height > 0)
}
