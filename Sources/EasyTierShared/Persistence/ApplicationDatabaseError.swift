import Foundation

package enum ApplicationDatabaseError: LocalizedError, Sendable {
    case integrityCheckFailed(String)
    case invalidStoredData(String)
    case secretInDatabasePayload(String)
    case unsupportedPayloadVersion(table: String, version: Int)

    package var errorDescription: String? {
        switch self {
        case let .integrityCheckFailed(message):
            "Database integrity check failed: \(message)"
        case let .invalidStoredData(message):
            "Saved application data is invalid: \(message)"
        case let .secretInDatabasePayload(configID):
            "Network configuration \(configID) contains a secret that must only be stored in Keychain."
        case let .unsupportedPayloadVersion(table, version):
            "Unsupported payload version \(version) in \(table)."
        }
    }
}
