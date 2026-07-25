import Foundation

public enum PersistenceHealth: Equatable, Sendable {
    case preparing
    case ready
    case unavailable(PersistenceFailure)
}
