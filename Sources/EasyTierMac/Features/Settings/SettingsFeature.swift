import Foundation
import Observation

@MainActor
@Observable
final class SettingsFeature {
    let appearance: AppAppearanceSettings
    let loginItem: LoginItemController

    var requestedTab: EasyTierSettingsTab {
        didSet {
            userDefaults.set(requestedTab.rawValue, forKey: Self.requestedTabKey)
        }
    }

    @ObservationIgnored private let userDefaults: UserDefaults

    init(
        appearance: AppAppearanceSettings,
        loginItem: LoginItemController,
        userDefaults: UserDefaults
    ) {
        self.appearance = appearance
        self.loginItem = loginItem
        self.userDefaults = userDefaults
        requestedTab = userDefaults.string(forKey: Self.requestedTabKey)
            .flatMap(EasyTierSettingsTab.init(rawValue:)) ?? .general
    }

    func request(_ tab: EasyTierSettingsTab) {
        requestedTab = tab
    }

    private static let requestedTabKey = "EasyTierSettingsTab"
}
