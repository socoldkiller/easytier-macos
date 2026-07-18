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

    private enum CodingKeys: String, CodingKey {
        case sourceBuild
        case targetBuild
        case configIDs
        case gatewayDesiredEnabled
        case createdAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceBuild = try container.decode(String.self, forKey: .sourceBuild)
        targetBuild = try container.decode(String.self, forKey: .targetBuild)
        configIDs = try container.decode([String].self, forKey: .configIDs)
        gatewayDesiredEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .gatewayDesiredEnabled
        ) ?? false
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}
