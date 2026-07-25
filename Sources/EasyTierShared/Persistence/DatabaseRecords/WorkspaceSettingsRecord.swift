import GRDB

struct WorkspaceSettingsRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "workspace_settings"

    var id: Int64 = 1
    var selectedConfigID: String?
    var rpcListenEnabled: Bool
    var rpcListenPort: Int
    var rpcPortalWhitelistJSON: String
    var vpnOnDemandEnabled: Bool
    var magicDNSSuffix: String
}
