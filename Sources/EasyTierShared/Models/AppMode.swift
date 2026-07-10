import Foundation

public struct AppMode: Codable, Equatable, Sendable {
    /// EasyTier core's rpc_portal default starts by trying TCP 15888.
    public static let defaultRPCListenPort = 15_888
    public static let defaultRPCPortalWhitelist = ["127.0.0.0/8"]

    public static let `default` = AppMode()

    public var rpcListenEnabled: Bool
    public var rpcListenPort: Int
    public var rpcPortalWhitelist: [String]?

    public init(
        rpcListenEnabled: Bool = true,
        rpcListenPort: Int = defaultRPCListenPort,
        rpcPortalWhitelist: [String]? = defaultRPCPortalWhitelist
    ) {
        self.rpcListenEnabled = rpcListenEnabled
        self.rpcListenPort = rpcListenPort
        self.rpcPortalWhitelist = rpcPortalWhitelist
    }

    public var label: String { "Normal" }

    public var rpcPortal: String? {
        rpcListenEnabled ? "tcp://0.0.0.0:\(rpcListenPort)" : nil
    }

    public var localRPCURL: URL? {
        guard rpcListenEnabled else { return nil }
        return URL(string: "tcp://127.0.0.1:\(rpcListenPort)")
    }
}
