public struct AppSnapshot: Codable, Equatable, Sendable {
    public var configs: [StoredNetworkConfig]
    public var mode: AppMode?
    public var lastSelectedConfigID: String?
    public var deviceAliases: [DeviceAlias]

    public init(
        configs: [StoredNetworkConfig],
        mode: AppMode?,
        lastSelectedConfigID: String?,
        deviceAliases: [DeviceAlias] = []
    ) {
        self.configs = configs
        self.mode = mode
        self.lastSelectedConfigID = lastSelectedConfigID
        self.deviceAliases = deviceAliases
    }

    private enum CodingKeys: String, CodingKey {
        case configs
        case mode
        case lastSelectedConfigID
        case deviceAliases
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        configs = try container.decode([StoredNetworkConfig].self, forKey: .configs)
        mode = try container.decodeIfPresent(AppMode.self, forKey: .mode)
        lastSelectedConfigID = try container.decodeIfPresent(String.self, forKey: .lastSelectedConfigID)
        deviceAliases = try container.decodeIfPresent([DeviceAlias].self, forKey: .deviceAliases) ?? []
    }
}
