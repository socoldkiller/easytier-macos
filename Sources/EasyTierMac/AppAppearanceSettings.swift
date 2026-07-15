import AppKit
import Foundation
import Observation

@MainActor
protocol DockIconApplication: AnyObject {
    func setActivationPolicy(_ activationPolicy: NSApplication.ActivationPolicy) -> Bool
    func activate(ignoringOtherApps flag: Bool)
}

extension NSApplication: DockIconApplication {}

@Observable
@MainActor
final class AppAppearanceSettings {
    typealias DockIconVisibilityApplier = @MainActor (Bool) -> Void

    var glassEffectsEnabled: Bool {
        didSet {
            userDefaults.set(glassEffectsEnabled, forKey: Self.glassEffectsEnabledKey)
        }
    }

    var glassPanelBackgroundsEnabled: Bool {
        didSet {
            userDefaults.set(glassPanelBackgroundsEnabled, forKey: Self.glassPanelBackgroundsEnabledKey)
        }
    }

    var showsDockIcon: Bool {
        didSet {
            guard showsDockIcon != oldValue else { return }
            userDefaults.set(showsDockIcon, forKey: Self.showsDockIconKey)
            applyDockIconVisibility(showsDockIcon)
        }
    }

    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private let applyDockIconVisibility: DockIconVisibilityApplier

    init(
        userDefaults: UserDefaults = .standard,
        applyDockIconVisibility: @escaping DockIconVisibilityApplier = {
            AppAppearanceSettings.applyDockIconVisibility($0)
        }
    ) {
        self.userDefaults = userDefaults
        self.applyDockIconVisibility = applyDockIconVisibility
        if userDefaults.object(forKey: Self.glassEffectsEnabledKey) == nil {
            glassEffectsEnabled = false
        } else {
            glassEffectsEnabled = userDefaults.bool(forKey: Self.glassEffectsEnabledKey)
        }
        if userDefaults.object(forKey: Self.glassPanelBackgroundsEnabledKey) == nil {
            glassPanelBackgroundsEnabled = false
        } else {
            glassPanelBackgroundsEnabled = userDefaults.bool(forKey: Self.glassPanelBackgroundsEnabledKey)
        }
        showsDockIcon = Self.persistedShowsDockIcon(userDefaults: userDefaults)
    }

    static func persistedShowsDockIcon(userDefaults: UserDefaults = .standard) -> Bool {
        guard userDefaults.object(forKey: showsDockIconKey) != nil else { return true }
        return userDefaults.bool(forKey: showsDockIconKey)
    }

    static func activationPolicy(showsDockIcon: Bool) -> NSApplication.ActivationPolicy {
        showsDockIcon ? .regular : .accessory
    }

    static func applyDockIconVisibility(
        _ showsDockIcon: Bool,
        application: any DockIconApplication = NSApp
    ) {
        guard application.setActivationPolicy(activationPolicy(showsDockIcon: showsDockIcon)) else { return }
        application.activate(ignoringOtherApps: true)
    }

    private static let glassEffectsEnabledKey = "EasyTierGlassEffectsEnabled"
    private static let glassPanelBackgroundsEnabledKey = "EasyTierGlassPanelBackgroundsEnabled"
    private static let showsDockIconKey = "EasyTierShowsDockIcon"
}
