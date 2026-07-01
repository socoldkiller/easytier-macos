import Foundation

public enum EasyTierCoreError: LocalizedError, Equatable {
    case ffiUnavailable(String)
    case operationFailed(String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case let .ffiUnavailable(message):
            "EasyTier FFI is unavailable: \(message)"
        case let .operationFailed(message):
            message
        case let .invalidResponse(message):
            "Invalid EasyTier response: \(message)"
        }
    }
}

public protocol EasyTierCoreClient: Sendable {
    func version() async throws -> String
    func validate(toml: String) async throws
    func run(config: NetworkConfig) async throws
    func run(toml: String) async throws
    func stop(instanceNames: [String]) async throws
    func retain(instanceNames: [String]) async throws
    func listInstances() async throws -> [NetworkInstance]
    func collectNetworkInfos() async throws -> [String: NetworkInstanceRunningInfo]
    func configureRPCPortal(_ rpcPortal: String?, whitelist: [String]?) async throws
    func callJSONRPC(service: String, method: String, domain: String?, payload: String) async throws -> String
    func connectRPCClient(clientID: String, url: URL) async throws
    func disconnectRPCClient(clientID: String) async throws
    func startConfigServerClient(url: URL) async throws
    func stopConfigServerClient() async throws
    func isConfigServerClientConnected() async throws -> Bool
}

public protocol EasyTierHelperShutdownClient: Sendable {
    func shutdownHelper() async throws
}

public struct UnavailableEasyTierCoreClient: EasyTierCoreClient {
    public let reason: String

    public init(reason: String = "Run scripts/build-ffi.sh to create Vendor/Frameworks/EasyTierFFI.xcframework.") {
        self.reason = reason
    }

    public func version() async throws -> String { "FFI not loaded" }
    public func validate(toml _: String) async throws { throw unavailable() }
    public func run(config _: NetworkConfig) async throws { throw unavailable() }
    public func run(toml _: String) async throws { throw unavailable() }
    public func stop(instanceNames _: [String]) async throws { throw unavailable() }
    public func retain(instanceNames _: [String]) async throws { throw unavailable() }
    public func listInstances() async throws -> [NetworkInstance] { throw unavailable() }
    public func collectNetworkInfos() async throws -> [String: NetworkInstanceRunningInfo] { throw unavailable() }
    public func configureRPCPortal(_ rpcPortal: String?, whitelist _: [String]?) async throws {
        if rpcPortal != nil { throw unavailable() }
    }
    public func callJSONRPC(service _: String, method _: String, domain _: String?, payload _: String) async throws -> String { throw unavailable() }
    public func connectRPCClient(clientID _: String, url _: URL) async throws { throw unavailable() }
    public func disconnectRPCClient(clientID _: String) async throws { throw unavailable() }
    public func startConfigServerClient(url _: URL) async throws { throw unavailable() }
    public func stopConfigServerClient() async throws { throw unavailable() }
    public func isConfigServerClientConnected() async throws -> Bool { throw unavailable() }

    private func unavailable() -> EasyTierCoreError {
        .ffiUnavailable(reason)
    }
}
