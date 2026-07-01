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

    @ObservationIgnored private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
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
    }

    private static let glassEffectsEnabledKey = "EasyTierGlassEffectsEnabled"
    private static let glassPanelBackgroundsEnabledKey = "EasyTierGlassPanelBackgroundsEnabled"
}
