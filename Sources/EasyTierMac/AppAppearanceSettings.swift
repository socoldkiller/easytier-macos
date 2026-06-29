import Foundation
import Observation

@Observable
final class AppAppearanceSettings {
    var glassEffectsEnabled: Bool {
        didSet {
            userDefaults.set(glassEffectsEnabled, forKey: Self.glassEffectsEnabledKey)
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
    }

    private static let glassEffectsEnabledKey = "EasyTierGlassEffectsEnabled"
}
