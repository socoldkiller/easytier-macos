public struct AppSnapshot: Codable, Equatable, Sendable {
    public var configs: [StoredNetworkConfig]
    public var mode: AppMode?
    public var lastSelectedConfigID: String?
    public var vpnOnDemandEnabled: Bool
    public var runtimeIntents: [RuntimeIntent]
    public var reversedPortForwardFingerprints: [String: Set<String>]
    public var magicDNSSettings: MagicDNSSettings

    public init(
        configs: [StoredNetworkConfig],
        mode: AppMode?,
        lastSelectedConfigID: String?,
        vpnOnDemandEnabled: Bool = false,
        runtimeIntents: [RuntimeIntent] = [],
        reversedPortForwardFingerprints: [String: Set<String>] = [:],
        magicDNSSettings: MagicDNSSettings = .default
    ) {
        self.configs = configs
        self.mode = mode
        self.lastSelectedConfigID = lastSelectedConfigID
        self.vpnOnDemandEnabled = vpnOnDemandEnabled
        self.runtimeIntents = runtimeIntents
        self.reversedPortForwardFingerprints = reversedPortForwardFingerprints
        self.magicDNSSettings = magicDNSSettings
    }

    private enum CodingKeys: String, CodingKey {
        case configs
        case mode
        case lastSelectedConfigID
        case vpnOnDemandEnabled
        case runtimeIntents
        case reversedPortForwardFingerprints
        case magicDNSSettings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        configs = try container.decode([StoredNetworkConfig].self, forKey: .configs)
        mode = try container.decodeIfPresent(AppMode.self, forKey: .mode)
        lastSelectedConfigID = try container.decodeIfPresent(String.self, forKey: .lastSelectedConfigID)
        vpnOnDemandEnabled = try container.decodeIfPresent(Bool.self, forKey: .vpnOnDemandEnabled) ?? false
        runtimeIntents = try container.decodeIfPresent([RuntimeIntent].self, forKey: .runtimeIntents) ?? []
        reversedPortForwardFingerprints = try container.decodeIfPresent([String: Set<String>].self, forKey: .reversedPortForwardFingerprints) ?? [:]
        magicDNSSettings = try container.decodeIfPresent(MagicDNSSettings.self, forKey: .magicDNSSettings) ?? .default
    }
}
