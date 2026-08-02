import GRDB

struct RemoteAccountRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "remote_account"

    var id: String
    var controlOrigin: String
    var username: String
    var payloadVersion: Int = 1
    var jsonPayload: String
}
