import Foundation
import Observation

@Observable
@MainActor
final class AppAppearanceSettings {
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
            dockIconVisibility.applyDockIconVisibility(showsDockIcon)
        }
    }

    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private let dockIconVisibility: any DockIconVisibilityApplying

    init(
        userDefaults: UserDefaults,
        dockIconVisibility: any DockIconVisibilityApplying
    ) {
        self.userDefaults = userDefaults
        self.dockIconVisibility = dockIconVisibility
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

    private static let glassEffectsEnabledKey = "EasyTierGlassEffectsEnabled"
    private static let glassPanelBackgroundsEnabledKey = "EasyTierGlassPanelBackgroundsEnabled"
    private static let showsDockIconKey = "EasyTierShowsDockIcon"
}
