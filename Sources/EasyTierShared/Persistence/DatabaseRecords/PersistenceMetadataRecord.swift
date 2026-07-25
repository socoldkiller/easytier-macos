import GRDB

struct PersistenceMetadataRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "persistence_metadata"

    var key: String
    var value: String
}
