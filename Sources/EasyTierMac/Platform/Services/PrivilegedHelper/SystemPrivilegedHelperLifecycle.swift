import EasyTierShared
import ServiceManagement

@MainActor
final class SystemPrivilegedHelperLifecycle: PrivilegedHelperLifecycle {
    private let services: [SMAppService]

    init(
        plistNames: [String] = [
            EasyTierPrivilegedHelperConstants.launchDaemonPlistName,
            GatewayPrivilegedHelperConstants.launchDaemonPlistName,
        ]
    ) {
        services = plistNames.map { .daemon(plistName: $0) }
    }

    func unregister() async throws {
        var firstError: Error?
        for service in services {
            do {
                try await service.unregister()
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }
}
