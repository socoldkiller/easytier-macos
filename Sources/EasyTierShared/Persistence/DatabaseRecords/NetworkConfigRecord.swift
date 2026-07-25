import GRDB

struct NetworkConfigRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "network_configs"

    var id: String
    var position: Int
    var payloadVersion: Int
    var tomlPayload: String
}
