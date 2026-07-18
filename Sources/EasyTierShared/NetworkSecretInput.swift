public enum NetworkSecretInput: Equatable, Sendable {
    case saved(String)
    case edited(String)

    public var value: String {
        switch self {
        case let .saved(value), let .edited(value):
            value
        }
    }

    public var isSaved: Bool {
        if case .saved = self { return true }
        return false
    }

    public var clearingSavedMaterial: NetworkSecretInput? {
        switch self {
        case .saved:
            nil
        case .edited:
            self
        }
    }

    public func applying(_ outcome: NetworkSecretOperationOutcome) -> NetworkSecretInput {
        guard outcome.didPersistEditedSecret else { return self }
        return switch self {
        case .saved:
            self
        case let .edited(value):
            .saved(value)
        }
    }
}
