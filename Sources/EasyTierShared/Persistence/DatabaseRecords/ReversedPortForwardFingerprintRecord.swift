import GRDB

struct ReversedPortForwardFingerprintRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "reversed_port_forward_fingerprints"

    var configID: String
    var fingerprint: String
}
