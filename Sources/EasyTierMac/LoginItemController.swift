import ServiceManagement
import SwiftUI

@Observable
final class LoginItemController {
    var isEnabled: Bool {
        didSet { userDefaults.set(isEnabled, forKey: Self.key) }
    }

    @ObservationIgnored private let service: SMAppService
    @ObservationIgnored private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.service = .mainApp
        self.userDefaults = userDefaults
        let stored = userDefaults.object(forKey: Self.key) as? Bool
        self.isEnabled = stored ?? (Self.service.status == .enabled)
    }

    func refresh() {
        isEnabled = Self.service.status == .enabled
    }

    func apply() {
        do {
            if isEnabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            isEnabled = Self.service.status == .enabled
        }
    }

    private static var service: SMAppService { .mainApp }

    private static let key = "EasyTierLaunchAtLogin"
}