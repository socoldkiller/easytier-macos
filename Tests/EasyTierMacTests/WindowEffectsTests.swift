import AppKit
import Testing
@testable import EasyTierMac
@testable import EasyTierShared

@MainActor
@Test func glassSurfaceRolesUseSemanticMaterialsAndNativeWindowState() {
    let expectations: [(GlassSurfaceRole, NSVisualEffectView.Material, NSVisualEffectView.BlendingMode)] = [
        (.windowBackdrop, .underWindowBackground, .behindWindow),
        (.sidebar, .sidebar, .behindWindow),
        (.panel, .sidebar, .withinWindow),
        (.sheet, .sheet, .behindWindow),
        (.popover, .popover, .behindWindow),
    ]

    for (role, material, blendingMode) in expectations {
        let configuration = role.configuration(reduceTransparency: false)
        #expect(configuration.material == material)
        #expect(configuration.blendingMode == blendingMode)
        #expect(configuration.state == .followsWindowActiveState)
        #expect(configuration.isEnabled)
    }

    #expect(!GlassSurfaceRole.windowBackdrop.configuration(reduceTransparency: true).isEnabled)
}

@MainActor
@Test func managedVisualEffectConfigurationIsIdempotent() {
    let host = ManagedVisualEffectHostView()
    let configuration = GlassSurfaceRole.windowBackdrop.configuration(reduceTransparency: false)
    host.reconcileRendering(isEligible: true)

    #expect(host.apply(configuration: configuration))
    #expect(host.effectView != nil)
    #expect(host.configurationApplyCount == 1)

    for _ in 0..<100_000 {
        #expect(!host.apply(configuration: configuration))
    }

    #expect(host.configurationApplyCount == 1)

    var changed = configuration
    changed.material = .sidebar
    #expect(host.apply(configuration: changed))
    #expect(host.configurationApplyCount == 2)
    #expect(host.effectView?.material == .sidebar)
}

@MainActor
@Test func managedVisualEffectHostReleasesAndRecreatesItsEffectChild() throws {
    let host = ManagedVisualEffectHostView()
    let configuration = GlassSurfaceRole.sidebar.configuration(reduceTransparency: false)
    host.reconcileRendering(isEligible: true)
    _ = host.apply(configuration: configuration)

    let originalEffectView = try #require(host.effectView)

    host.reconcileRendering(isEligible: false)
    #expect(host.effectView == nil)

    host.reconcileRendering(isEligible: true)
    #expect(host.effectView != nil)
    #expect(host.effectView !== originalEffectView)
    #expect(host.effectView?.material == .sidebar)
    #expect(host.effectView?.blendingMode == .behindWindow)
    #expect(host.effectView?.state == .followsWindowActiveState)
}

@Test func windowPresentationActivityReflectsVisibilityAndInteraction() {
    #expect(WindowPresentationActivityResolver.evaluate(
        renderEligible: false,
        applicationActive: true,
        windowKey: true
    ) == .suspended)
    #expect(WindowPresentationActivityResolver.evaluate(
        renderEligible: true,
        applicationActive: false,
        windowKey: true
    ) == .visibleInactive)
    #expect(WindowPresentationActivityResolver.evaluate(
        renderEligible: true,
        applicationActive: true,
        windowKey: false
    ) == .visibleInactive)
    #expect(WindowPresentationActivityResolver.evaluate(
        renderEligible: true,
        applicationActive: true,
        windowKey: true
    ) == .interactive)
}

@MainActor
@Test func unattachedWindowAccessorDoesNotReportFalseSuspension() {
    let accessor = WindowAccessorView()
    var activities: [RuntimePresentationActivity] = []
    accessor.activityDidChange = { activities.append($0) }

    accessor.applyCurrentWindowState()
    accessor.stopObserving()

    #expect(activities.isEmpty)
}

@MainActor
@Test func initiallyHiddenWindowDoesNotReportFalseSuspension() {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    let accessor = WindowAccessorView()
    var activities: [RuntimePresentationActivity] = []
    accessor.activityDidChange = { activities.append($0) }

    window.contentView = accessor
    accessor.applyCurrentWindowState()
    accessor.stopObserving()

    #expect(!window.isVisible)
    #expect(activities.isEmpty)
}

@Test func windowRenderEligibilityRequiresAnActuallyVisibleWindow() {
    #expect(WindowRenderEligibility.evaluate(
        screenAvailable: true,
        sessionActive: true,
        windowAttached: true,
        windowVisible: true,
        windowMiniaturized: false,
        windowOcclusionVisible: true
    ))

    #expect(!WindowRenderEligibility.evaluate(
        screenAvailable: true,
        sessionActive: true,
        windowAttached: true,
        windowVisible: true,
        windowMiniaturized: false,
        windowOcclusionVisible: false
    ))

    #expect(!WindowRenderEligibility.evaluate(
        screenAvailable: false,
        sessionActive: true,
        windowAttached: true,
        windowVisible: true,
        windowMiniaturized: false,
        windowOcclusionVisible: true
    ))
}

@MainActor
@Test func easyTierWindowConfiguratorIgnoresForeignWindows() {
    let foreign = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    foreign.identifier = NSUserInterfaceItemIdentifier("SUUpdateAlert")
    foreign.isOpaque = true
    foreign.backgroundColor = .controlBackgroundColor
    let originalStyleMask = foreign.styleMask

    #expect(!EasyTierWindowConfigurator.configureIfOwned(foreign, effectiveGlass: true))
    #expect(foreign.styleMask == originalStyleMask)
    #expect(foreign.isOpaque)
    #expect(foreign.backgroundColor == .controlBackgroundColor)

    foreign.identifier = EasyTierWindowRole.main.identifier
    #expect(EasyTierWindowConfigurator.configureIfOwned(foreign, effectiveGlass: true))
    #expect(foreign.styleMask.contains(.fullSizeContentView))
    #expect(!foreign.isOpaque)
    #expect(foreign.backgroundColor == .clear)
}
