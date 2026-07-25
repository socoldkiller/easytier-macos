import Foundation

public struct PersistenceFailure: Equatable, Sendable {
    public var message: String
    public var databaseURL: URL

    public init(message: String, databaseURL: URL) {
        self.message = message
        self.databaseURL = databaseURL
    }
}
