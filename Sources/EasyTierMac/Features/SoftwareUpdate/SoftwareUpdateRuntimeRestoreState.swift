import Foundation

struct SoftwareUpdateRuntimeRestoreState: Codable, Equatable {
    var sourceBuild: String
    var targetBuild: String
    var configIDs: [String]
    var createdAt: Date
}
