import Foundation

package struct RemoteAccountProfile: Codable, Equatable, Sendable {
    package var controlOrigin: URL
    package var configEndpoint: String
    package var consoleURL: URL
    package var username: String
    package var machineID: UUID
    package var createdAt: Date
    package var updatedAt: Date

    package init(
        controlOrigin: URL,
        configEndpoint: String,
        consoleURL: URL,
        username: String,
        machineID: UUID,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.controlOrigin = controlOrigin
        self.configEndpoint = configEndpoint
        self.consoleURL = consoleURL
        self.username = username
        self.machineID = machineID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
