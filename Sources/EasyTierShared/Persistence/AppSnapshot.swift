public struct AppSnapshot: Codable, Equatable, Sendable {
    public var configs: [StoredNetworkConfig]
    public var mode: AppMode?
    public var lastSelectedConfigID: String?
    public var runtimeIntents: [RuntimeIntent]
    public var reversedPortForwardFingerprints: [String: Set<String>]

    public init(
        configs: [StoredNetworkConfig],
        mode: AppMode?,
        lastSelectedConfigID: String?,
        runtimeIntents: [RuntimeIntent] = [],
        reversedPortForwardFingerprints: [String: Set<String>] = [:]
    ) {
        self.configs = configs
        self.mode = mode
        self.lastSelectedConfigID = lastSelectedConfigID
        self.runtimeIntents = runtimeIntents
        self.reversedPortForwardFingerprints = reversedPortForwardFingerprints
    }

    private enum CodingKeys: String, CodingKey {
        case configs
        case mode
        case lastSelectedConfigID
        case runtimeIntents
        case reversedPortForwardFingerprints
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        configs = try container.decode([StoredNetworkConfig].self, forKey: .configs)
        mode = try container.decodeIfPresent(AppMode.self, forKey: .mode)
        lastSelectedConfigID = try container.decodeIfPresent(String.self, forKey: .lastSelectedConfigID)
        runtimeIntents = try container.decodeIfPresent([RuntimeIntent].self, forKey: .runtimeIntents) ?? []
        reversedPortForwardFingerprints = try container.decodeIfPresent([String: Set<String>].self, forKey: .reversedPortForwardFingerprints) ?? [:]
    }
}
