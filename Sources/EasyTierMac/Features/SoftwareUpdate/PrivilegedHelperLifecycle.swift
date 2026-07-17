@MainActor
protocol PrivilegedHelperLifecycle: AnyObject {
    func unregister() async throws
}
