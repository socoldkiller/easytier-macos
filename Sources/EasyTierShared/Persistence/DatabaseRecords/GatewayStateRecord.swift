import GRDB

struct GatewayStateRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "gateway_state"

    var id: Int64 = 1
    var configurationID: String
    var revision: Int64
    var payloadVersion: Int
    var jsonPayload: String
}
