import EasyTierShared
import ServiceManagement

@MainActor
final class SystemPrivilegedHelperLifecycle: PrivilegedHelperLifecycle {
    private let service: SMAppService

    init(
        plistName: String = EasyTierPrivilegedHelperConstants.launchDaemonPlistName
    ) {
        service = .daemon(plistName: plistName)
    }

    func unregister() async throws {
        try await service.unregister()
    }
}
