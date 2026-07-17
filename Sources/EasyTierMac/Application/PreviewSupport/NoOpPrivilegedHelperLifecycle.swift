@MainActor
final class NoOpPrivilegedHelperLifecycle: PrivilegedHelperLifecycle {
    func unregister() async throws {}
}
