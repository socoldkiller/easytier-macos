import GRDB

struct PeerSubscriptionRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "peer_subscriptions"

    var id: String
    var position: Int
    var name: String
    var subscriptionURL: String?
    var lastFetchedAt: Double?
}
