public struct DeviceAlias: Codable, Equatable, Identifiable, Sendable {
    public var networkID: String
    public var peerID: String
    public var hostname: String
    public var displayName: String

    public var id: String { "\(networkID)-\(peerID)" }

    public init(networkID: String, peerID: String, hostname: String, displayName: String) {
        self.networkID = networkID
        self.peerID = peerID
        self.hostname = hostname
        self.displayName = displayName
    }
}
