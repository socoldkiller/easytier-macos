public struct AppSnapshot: Codable, Equatable, Sendable {
    public var configs: [StoredNetworkConfig]
    public var mode: AppMode?
    public var lastSelectedConfigID: String?
    public var runtimeIntents: [RuntimeIntent]

    public init(
        configs: [StoredNetworkConfig],
        mode: AppMode?,
        lastSelectedConfigID: String?,
        runtimeIntents: [RuntimeIntent] = []
    ) {
        self.configs = configs
        self.mode = mode
        self.lastSelectedConfigID = lastSelectedConfigID
        self.runtimeIntents = runtimeIntents
    }

    private enum CodingKeys: String, CodingKey {
        case configs
        case mode
        case lastSelectedConfigID
        case runtimeIntents
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        configs = try container.decode([StoredNetworkConfig].self, forKey: .configs)
        mode = try container.decodeIfPresent(AppMode.self, forKey: .mode)
        lastSelectedConfigID = try container.decodeIfPresent(String.self, forKey: .lastSelectedConfigID)
        runtimeIntents = try container.decodeIfPresent([RuntimeIntent].self, forKey: .runtimeIntents) ?? []
    }
}
