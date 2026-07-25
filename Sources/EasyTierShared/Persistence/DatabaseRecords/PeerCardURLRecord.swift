import GRDB

struct PeerCardURLRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "peer_card_urls"

    var subscriptionID: String
    var cardID: String
    var position: Int
    var url: String
}
