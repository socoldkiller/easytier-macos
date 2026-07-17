import ServiceManagement

@MainActor
final class SystemLoginItemService: LoginItemService {
    private let service: SMAppService

    init(service: SMAppService = .mainApp) {
        self.service = service
    }

    var isEnabled: Bool {
        service.status == .enabled
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }
}
