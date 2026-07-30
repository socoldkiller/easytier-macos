import GRDB

struct RemoteAccountRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "remote_account"

    var id: Int64 = 1
    var payloadVersion: Int = 1
    var jsonPayload: String
}
