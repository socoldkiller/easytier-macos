public struct NetworkSecretOperationOutcome: Equatable, Sendable {
    public var didPersistEditedSecret: Bool

    public init(didPersistEditedSecret: Bool = false) {
        self.didPersistEditedSecret = didPersistEditedSecret
    }

    public static let none = NetworkSecretOperationOutcome()
}
