import GRDB

struct RuntimeIntentRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "runtime_intents"

    var id: String
    var position: Int
    var networkName: String
    var instanceID: String?
    var peerID: String?
    var recentHostname: String?
    var recentIPv4: String?
    var isLocal: Bool
    var desiredHostname: String
    var baseHostname: String?
    var status: String
    var updatedAt: Double
}
