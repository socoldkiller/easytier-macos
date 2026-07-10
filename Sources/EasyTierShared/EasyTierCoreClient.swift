import Foundation

package enum EasyTierCoreError: LocalizedError, Equatable {
    case operationFailed(String)
    case invalidResponse(String)

    package var errorDescription: String? {
        switch self {
        case let .operationFailed(message):
            message
        case let .invalidResponse(message):
            "Invalid EasyTier response: \(message)"
        }
    }
}

package protocol EasyTierCoreClient: Sendable {
    func validate(toml: String) async throws
    func run(toml: String) async throws
    func stop(instanceNames: [String]) async throws
    func retain(instanceNames: [String]) async throws
    func collectNetworkInfos() async throws -> [String: NetworkInstanceRunningInfo]
    func configureRPCPortal(_ rpcPortal: String?, whitelist: [String]?) async throws
    func callJSONRPC(
        clientID: String,
        url: URL,
        service: String,
        method: String,
        domain: String?,
        payload: String
    ) async throws -> String
}

package protocol EasyTierHelperShutdownClient: Sendable {
    func shutdownHelper() async throws
}
