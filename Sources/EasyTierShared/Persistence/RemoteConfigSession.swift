import Foundation

public enum RemoteConfigApplyState: Equatable, Sendable {
    case idle
    case applying
    case applied
    case failed(String)

    public var isApplying: Bool {
        self == .applying
    }
}

public struct RemoteConfigSession: Sendable {
    let requestID: UUID
    public let rpcURL: URL
    public let instanceID: String
    public let member: NetworkMemberStatus
    public var config: NetworkConfig {
        didSet {
            if config != oldValue, !applyState.isApplying {
                applyState = .idle
            }
        }
    }
    public var originalConfig: NetworkConfig
    public var isLoading: Bool
    public var loadError: String?
    public var applyState: RemoteConfigApplyState
    package var originalConfigPayload: Data?

    public var hasUnsavedChanges: Bool {
        config != originalConfig
    }

    package init(
        requestID: UUID = UUID(),
        rpcURL: URL,
        instanceID: String,
        member: NetworkMemberStatus,
        config: NetworkConfig,
        originalConfig: NetworkConfig,
        isLoading: Bool,
        loadError: String?,
        applyState: RemoteConfigApplyState = .idle,
        originalConfigPayload: Data? = nil
    ) {
        self.requestID = requestID
        self.rpcURL = rpcURL
        self.instanceID = instanceID
        self.member = member
        self.config = config
        self.originalConfig = originalConfig
        self.isLoading = isLoading
        self.loadError = loadError
        self.applyState = applyState
        self.originalConfigPayload = originalConfigPayload
    }
}

enum RemoteConfigSessionCoordinator {
    static func preparedSession(for member: NetworkMemberStatus) -> RemoteConfigSession {
        guard member.isLive,
              let instanceID = member.instanceID,
              let ip = member.copyableIPv4Address,
              let rpcURL = URL(string: "tcp://\(ip):\(AppMode.defaultRPCListenPort)")
        else {
            return RemoteConfigSession(
                rpcURL: placeholderRPCURL,
                instanceID: member.instanceID ?? "",
                member: member,
                config: NetworkConfig(),
                originalConfig: NetworkConfig(),
                isLoading: false,
                loadError: member.isLive
                    ? "Remote instance ID or virtual IP is unavailable for \(member.hostname)."
                    : "\(member.hostname) is still reconnecting. Try again after it is online."
            )
        }

        return RemoteConfigSession(
            rpcURL: rpcURL,
            instanceID: instanceID,
            member: member,
            config: NetworkConfig(),
            originalConfig: NetworkConfig(),
            isLoading: true,
            loadError: nil
        )
    }

    static func load(
        _ session: RemoteConfigSession,
        client providedClient: EasyTierRemoteRPCClient? = nil
    ) async -> RemoteConfigSession {
        guard session.isLoading else { return session }
        var session = session
        do {
            let client = providedClient ?? EasyTierRemoteRPCClient(rpcURL: session.rpcURL)
            let document = try await client
                .getConfigDocument(instanceID: session.instanceID)
            session.config = document.config
            session.originalConfig = document.config
            session.originalConfigPayload = document.rawConfig
            session.isLoading = false
        } catch {
            session.isLoading = false
            session.loadError = error.localizedDescription
        }
        return session
    }

    static func validate(
        _ session: RemoteConfigSession,
        client providedClient: EasyTierRemoteRPCClient? = nil
    ) async throws {
        let client = providedClient ?? EasyTierRemoteRPCClient(rpcURL: session.rpcURL)
        _ = try await client.validateNetworkConfig(
            session.config,
            originalConfig: session.originalConfig,
            preserving: session.originalConfigPayload
        )
    }

    static func restart(
        _ session: RemoteConfigSession,
        client providedClient: EasyTierRemoteRPCClient? = nil
    ) async throws {
        let client = providedClient ?? EasyTierRemoteRPCClient(rpcURL: session.rpcURL)
        _ = try await client.restartNetworkInstance(
            instanceID: session.instanceID,
            config: session.config,
            originalConfig: session.originalConfig,
            preserving: session.originalConfigPayload
        )
    }

    private static let placeholderRPCURL =
        URL(string: "tcp://0.0.0.0:0") ?? URL(fileURLWithPath: "/dev/null")
}
