import AppKit
import Foundation
import Testing
@testable import EasyTierMac

@MainActor
@Test func dockIconIsVisibleByDefaultAndPersistsChanges() {
    let suiteName = "AppAppearanceSettingsTests.\(UUID().uuidString)"
    let userDefaults = UserDefaults(suiteName: suiteName)!
    defer { userDefaults.removePersistentDomain(forName: suiteName) }

    var appliedVisibility: [Bool] = []
    let settings = AppAppearanceSettings(
        userDefaults: userDefaults,
        applyDockIconVisibility: { appliedVisibility.append($0) }
    )

    #expect(settings.showsDockIcon)
    #expect(appliedVisibility.isEmpty)

    settings.showsDockIcon = false

    #expect(userDefaults.object(forKey: "EasyTierShowsDockIcon") as? Bool == false)
    #expect(appliedVisibility == [false])

    let restoredSettings = AppAppearanceSettings(
        userDefaults: userDefaults,
        applyDockIconVisibility: { _ in }
    )
    #expect(!restoredSettings.showsDockIcon)
}

@MainActor
@Test func dockIconVisibilityMapsToExpectedActivationPolicy() {
    #expect(AppAppearanceSettings.activationPolicy(showsDockIcon: true) == .regular)
    #expect(AppAppearanceSettings.activationPolicy(showsDockIcon: false) == .accessory)
}

@MainActor
@Test func hidingDockIconKeepsApplicationInFront() {
    let application = TestDockIconApplication()

    AppAppearanceSettings.applyDockIconVisibility(false, application: application)

    #expect(application.activationPolicies == [.accessory])
    #expect(application.activateIgnoringOtherAppsValues == [true])
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
