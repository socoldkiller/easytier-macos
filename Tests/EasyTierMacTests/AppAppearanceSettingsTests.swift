import AppKit
import Foundation
import Testing
@testable import EasyTierMac

@MainActor
@Test func dockIconIsVisibleByDefaultAndPersistsChanges() {
    let suiteName = "AppAppearanceSettingsTests.\(UUID().uuidString)"
    let userDefaults = UserDefaults(suiteName: suiteName)!
    defer { userDefaults.removePersistentDomain(forName: suiteName) }

    let dockIconVisibility = TestDockIconVisibilityService()
    let settings = AppAppearanceSettings(
        userDefaults: userDefaults,
        dockIconVisibility: dockIconVisibility
    )

    #expect(settings.showsDockIcon)
    #expect(dockIconVisibility.appliedVisibility.isEmpty)

    settings.showsDockIcon = false

    #expect(userDefaults.object(forKey: "EasyTierShowsDockIcon") as? Bool == false)
    #expect(dockIconVisibility.appliedVisibility == [false])

    let restoredSettings = AppAppearanceSettings(
        userDefaults: userDefaults,
        dockIconVisibility: TestDockIconVisibilityService()
    )
    #expect(!restoredSettings.showsDockIcon)
}

@MainActor
@Test func dockIconVisibilityMapsToExpectedActivationPolicy() {
    #expect(SystemDockIconVisibilityService.activationPolicy(showsDockIcon: true) == .regular)
    #expect(SystemDockIconVisibilityService.activationPolicy(showsDockIcon: false) == .accessory)
}

@MainActor
@Test func dockIconApplicationIsResolvedOnlyWhenVisibilityIsApplied() {
    let application = TestDockIconApplication()
    var resolutionCount = 0
    let service = SystemDockIconVisibilityService {
        resolutionCount += 1
        return application
    }

    #expect(resolutionCount == 0)

    service.applyDockIconVisibility(true)

    #expect(resolutionCount == 1)
    #expect(application.activationPolicies == [.regular])
}

@MainActor
@Test func hidingDockIconKeepsApplicationInFront() {
    let application = TestDockIconApplication()

    SystemDockIconVisibilityService(application: application)
        .applyDockIconVisibility(false)

    #expect(application.activationPolicies == [.accessory])
    #expect(application.activateIgnoringOtherAppsValues == [true])
}

@MainActor
private final class TestDockIconVisibilityService: DockIconVisibilityApplying {
    private(set) var appliedVisibility: [Bool] = []

    func applyDockIconVisibility(_ showsDockIcon: Bool) {
        appliedVisibility.append(showsDockIcon)
    }
}

@MainActor
private final class TestDockIconApplication: DockIconApplication {
    var activationPolicies: [NSApplication.ActivationPolicy] = []
    var activateIgnoringOtherAppsValues: [Bool] = []

    func setActivationPolicy(_ activationPolicy: NSApplication.ActivationPolicy) -> Bool {
        activationPolicies.append(activationPolicy)
        return true
    }

    func activate(ignoringOtherApps flag: Bool) {
        activateIgnoringOtherAppsValues.append(flag)
    }
}
