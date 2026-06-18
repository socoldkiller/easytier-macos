public struct AppSnapshot: Codable, Equatable, Sendable {
    public var configs: [StoredNetworkConfig]
    public var mode: AppMode?
    public var lastSelectedConfigID: String?

    public init(
        configs: [StoredNetworkConfig],
        mode: AppMode?,
        lastSelectedConfigID: String?
    ) {
        self.configs = configs
        self.mode = mode
        self.lastSelectedConfigID = lastSelectedConfigID
    }

    private enum CodingKeys: String, CodingKey {
        case configs
        case mode
        case lastSelectedConfigID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        configs = try container.decode([StoredNetworkConfig].self, forKey: .configs)
        mode = try container.decodeIfPresent(AppMode.self, forKey: .mode)
        lastSelectedConfigID = try container.decodeIfPresent(String.self, forKey: .lastSelectedConfigID)
    }
}
