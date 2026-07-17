@MainActor
final class InMemoryLoginItemService: LoginItemService {
    var isEnabled: Bool

    init(isEnabled: Bool = false) {
        self.isEnabled = isEnabled
    }

    func register() throws {
        isEnabled = true
    }

    func unregister() throws {
        isEnabled = false
    }
}
