import Foundation

public enum LogLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case off
    case warn
    case info
    case debug
    case trace

    public var id: String { rawValue }
}

public enum AppMode: Codable, Equatable, Sendable {
    case normal(rpcPortal: String?, rpcListenEnabled: Bool, rpcListenPort: Int, configServerURL: URL?)
    case remote(remoteRPCAddress: String)
    case service(configDir: URL, rpcPortal: String, fileLogLevel: LogLevel, fileLogDir: URL, configServerURL: URL?)

    public static let defaultRPCListenPort = 15_888

    public static let `default`: AppMode = .normal(
        rpcPortal: nil,
        rpcListenEnabled: true,
        rpcListenPort: defaultRPCListenPort,
        configServerURL: nil
    )

    public var label: String {
        switch self {
        case let .normal(_, _, _, configServerURL):
            configServerURL == nil ? "Normal" : "Remote"
        case .remote:
            "Remote"
        case .service:
            "Service"
        }
    }

    public var configServerURL: URL? {
        switch self {
        case let .normal(_, _, _, url), let .service(_, _, _, _, url):
            url
        case .remote:
            nil
        }
    }

    public var rpcPortal: String? {
        switch self {
        case let .normal(rpcPortal, _, _, _):
            rpcPortal
        case let .service(_, rpcPortal, _, _, _):
            rpcPortal
        case .remote:
            nil
        }
    }
}

public enum ConfigSource: String, Codable, CaseIterable, Sendable {
    case legacy
    case user
    case web
}

public struct StoredNetworkConfig: Codable, Identifiable, Equatable, Sendable {
    public var config: NetworkConfig
    public var source: ConfigSource

    public var id: String { config.instance_id }

    public init(config: NetworkConfig, source: ConfigSource = .user) {
        self.config = config
        self.source = source
    }
}
