@MainActor
protocol LoginItemService: AnyObject {
    var isEnabled: Bool { get }

    func register() throws
    func unregister() throws
}
