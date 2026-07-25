import Foundation

struct SoftwareUpdateRuntimeRestoreState: Codable, Equatable {
    var sourceBuild: String
    var targetBuild: String
    var configIDs: [String]
    var gatewayDesiredEnabled: Bool
    var createdAt: Date

    init(
        sourceBuild: String,
        targetBuild: String,
        configIDs: [String],
        gatewayDesiredEnabled: Bool = false,
        createdAt: Date
    ) {
        self.sourceBuild = sourceBuild
        self.targetBuild = targetBuild
        self.configIDs = configIDs
        self.gatewayDesiredEnabled = gatewayDesiredEnabled
        self.createdAt = createdAt
    }

}
