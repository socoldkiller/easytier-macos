import Foundation

public enum AppMode: Codable, Equatable, Sendable {
    case normal(rpcPortal: String?, rpcListenEnabled: Bool, rpcListenPort: Int, rpcPortalWhitelist: [String]?, configServerURL: URL?)
    case remote(remoteRPCAddress: String)

    public static let defaultRPCListenPort = 15_888
    public static let defaultRPCPortalWhitelist = ["127.0.0.0/8", "::1/128"]

    public static let `default`: AppMode = .normal(
        rpcPortal: nil,
        rpcListenEnabled: true,
        rpcListenPort: defaultRPCListenPort,
        rpcPortalWhitelist: defaultRPCPortalWhitelist,
        configServerURL: nil
    )

    public var label: String {
        switch self {
        case let .normal(_, _, _, _, configServerURL):
            configServerURL == nil ? "Normal" : "Remote"
        case .remote:
            "Remote"
        }
    }

    public var configServerURL: URL? {
        switch self {
        case let .normal(_, _, _, _, url):
            url
        case .remote:
            nil
        }
    }

    public var rpcPortal: String? {
        switch self {
        case let .normal(rpcPortal, _, _, _, _):
            rpcPortal
        case .remote:
            nil
        }
    }

    public var rpcPortalWhitelist: [String]? {
        switch self {
        case let .normal(_, _, _, whitelist, _):
            whitelist
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
    public var tomlPath: String
    public var config: NetworkConfig
    public var source: ConfigSource

    public var id: String { config.instance_id }

    public init(config: NetworkConfig, source: ConfigSource = .user, tomlPath: String? = nil) {
        self.tomlPath = tomlPath ?? Self.defaultTOMLPath(for: config.instance_id)
        self.config = config
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case tomlPath
        case source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        tomlPath = try container.decode(String.self, forKey: .tomlPath)
        source = try container.decode(ConfigSource.self, forKey: .source)
        config = NetworkConfig(instance_id: id)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(tomlPath, forKey: .tomlPath)
        try container.encode(source, forKey: .source)
    }

    public static func defaultTOMLPath(for id: String) -> String {
        "configs/\(id).toml"
    }
}
