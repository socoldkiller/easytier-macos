import Foundation
import Testing
@testable import EasyTierMac

@MainActor
@Test func settingsFeatureOwnsAndPersistsNavigationState() {
    let fixture = makeArchitectureUserDefaults()
    defer { fixture.clear() }

    let first = makeSettingsFeature(userDefaults: fixture.defaults)
    #expect(first.requestedTab == .general)

    first.request(.gateway)

    let restored = makeSettingsFeature(userDefaults: fixture.defaults)
    #expect(restored.requestedTab == .gateway)
    #expect(EasyTierSettingsTab.allCases.contains(.gateway))
}

@MainActor
@Test func loginItemControllerUsesInjectedPlatformService() {
    let fixture = makeArchitectureUserDefaults()
    defer { fixture.clear() }

    let service = TestLoginItemService()
    let controller = LoginItemController(
        userDefaults: fixture.defaults,
        service: service
    )

    service.isEnabled = true
    controller.refresh()
    #expect(controller.isEnabled)

    controller.isEnabled = false
    controller.apply()
    #expect(service.unregisterCount == 1)

    controller.isEnabled = true
    controller.apply()
    #expect(service.registerCount == 1)
}

@MainActor
@Test func softwareUpdateFeatureCoordinatesRuntimeThroughProtocols() async throws {
    let fixture = makeArchitectureUserDefaults()
    defer { fixture.clear() }

    let runtime = TestSoftwareUpdateRuntime()
    let privilegedHelper = TestPrivilegedHelperLifecycle()
    let updateClient = TestArchitectureSoftwareUpdateClient()
    let feature = SoftwareUpdateFeature(
        runtime: runtime,
        privilegedHelper: privilegedHelper,
        userDefaults: fixture.defaults,
        currentBuild: "100",
        clientFactory: { _ in updateClient }
    )

    var installHandlerCount = 0
    let task = try #require(
        feature.controller.beginInstallationPreparation(targetBuild: "200") {
            installHandlerCount += 1
        }
    )
    await task.value

    #expect(runtime.captureCount == 1)
    #expect(runtime.prepareCount == 1)
    #expect(privilegedHelper.unregisterCount == 1)
    #expect(installHandlerCount == 1)
    #expect(runtime.notices == ["Privileged helper unregistered for software update."])
}

@MainActor
private func makeSettingsFeature(userDefaults: UserDefaults) -> SettingsFeature {
    SettingsFeature(
        appearance: AppAppearanceSettings(
            userDefaults: userDefaults,
            dockIconVisibility: TestDockIconVisibilityService()
        ),
        loginItem: LoginItemController(
            userDefaults: userDefaults,
            service: TestLoginItemService()
        ),
        userDefaults: userDefaults
    )
}

@MainActor
private final class TestLoginItemService: LoginItemService {
    var isEnabled = false
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0

    func register() throws {
        registerCount += 1
        isEnabled = true
    }

    func unregister() throws {
        unregisterCount += 1
        isEnabled = false
    }
}

@MainActor
private final class TestDockIconVisibilityService: DockIconVisibilityApplying {
    func applyDockIconVisibility(_: Bool) {}
}

@MainActor
private final class TestSoftwareUpdateRuntime: SoftwareUpdateRuntimeManaging {
    private(set) var captureCount = 0
    private(set) var prepareCount = 0
    private(set) var restoredConfigIDs: [[String]] = []
    private(set) var notices: [String] = []

    func runningConfigIDsForSoftwareUpdate() -> [String] {
        captureCount += 1
        return ["network-b", "network-a"]
    }

    func prepareForSoftwareUpdate() async {
        prepareCount += 1
    }

    func restoreConfigsAfterSoftwareUpdate(configIDs: [String]) async {
        restoredConfigIDs.append(configIDs)
    }

    func recordNotice(_ message: String) {
        notices.append(message)
    }
}

@MainActor
private final class TestPrivilegedHelperLifecycle: PrivilegedHelperLifecycle {
    private(set) var unregisterCount = 0

    func unregister() async throws {
        unregisterCount += 1
    }
}

@MainActor
private final class TestArchitectureSoftwareUpdateClient: SoftwareUpdateClient {
    var canCheckForUpdates = false
    var sessionInProgress = false
    var automaticallyChecksForUpdates = true
    var lastUpdateCheckDate: Date?
    var stateDidChange: (@MainActor () -> Void)?

    func start() {}
    func checkForUpdates() {}
    func resetUpdateCycleAfterShortDelay() {}
}

private func makeArchitectureUserDefaults() -> (defaults: UserDefaults, clear: () -> Void) {
    let suiteName = "AppArchitectureTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName) ?? UserDefaults()
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
}
