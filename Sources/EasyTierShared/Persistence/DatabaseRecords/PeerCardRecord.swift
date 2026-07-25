import GRDB

struct PeerCardRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "peer_cards"

    var subscriptionID: String
    var id: String
    var position: Int
    var name: String
    var proto: String
    var note: String?
}
