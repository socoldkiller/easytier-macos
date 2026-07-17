import Foundation
import Observation

@MainActor
@Observable
final class LoginItemController {
    var isEnabled: Bool {
        didSet { userDefaults.set(isEnabled, forKey: Self.key) }
    }

    @ObservationIgnored private let service: any LoginItemService
    @ObservationIgnored private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults, service: any LoginItemService) {
        self.service = service
        self.userDefaults = userDefaults
        let stored = userDefaults.object(forKey: Self.key) as? Bool
        self.isEnabled = stored ?? false
    }

    func refresh() {
        isEnabled = service.isEnabled
    }

    func apply() {
        do {
            if isEnabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            isEnabled = service.isEnabled
        }
    }

    private static let key = "EasyTierLaunchAtLogin"
}
