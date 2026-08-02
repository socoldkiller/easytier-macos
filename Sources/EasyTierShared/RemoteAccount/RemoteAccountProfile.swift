import Foundation

package struct RemoteAccountID: Codable, Hashable, Sendable {
    package let rawValue: UUID

    package init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(UUID.self)
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

package struct RemoteAccountProfile: Codable, Equatable, Sendable {
    package var controlOrigin: URL
    package var consoleURL: URL
    package var username: String

    package init(
        controlOrigin: URL,
        consoleURL: URL,
        username: String
    ) {
        self.controlOrigin = controlOrigin
        self.consoleURL = consoleURL
        self.username = username
    }
}

package struct RemoteDeviceBinding: Codable, Equatable, Sendable {
    package var configEndpoint: String
    package var machineID: UUID

    package init(configEndpoint: String, machineID: UUID) {
        self.configEndpoint = configEndpoint
        self.machineID = machineID
    }
}

package struct StoredRemoteAccount: Codable, Equatable, Sendable {
    package var id: RemoteAccountID
    package var profile: RemoteAccountProfile
    package var deviceBinding: RemoteDeviceBinding
    package var createdAt: Date
    package var updatedAt: Date

    package init(
        id: RemoteAccountID = RemoteAccountID(),
        profile: RemoteAccountProfile,
        deviceBinding: RemoteDeviceBinding,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.profile = profile
        self.deviceBinding = deviceBinding
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

}
