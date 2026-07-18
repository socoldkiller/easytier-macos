import EasyTierShared
import Foundation

final class PreviewEasyTierCoreClient: EasyTierCoreClient, EasyTierHelperShutdownClient, @unchecked Sendable {
    func validate(toml _: String) async throws {}

    func run(toml _: String) async throws {}

    func stop(instanceNames _: [String]) async throws {}

    func retain(instanceNames _: [String]) async throws {}

    func collectNetworkInfos() async throws -> [String: NetworkInstanceRunningInfo] {
        [:]
    }

    func configureRPCPortal(_: String?, whitelist _: [String]?) async throws {}

    func callJSONRPC(
        clientID _: String,
        url _: URL,
        service _: String,
        method _: String,
        domain _: String?,
        payload _: String
    ) async throws -> String {
        "{}"
    }

    func shutdownHelper() async throws {}
}
