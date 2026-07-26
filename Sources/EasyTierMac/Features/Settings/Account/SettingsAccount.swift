struct SettingsAccount: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let networkName: String
    let email: String
    let expirationSummary: String
    let isConnected: Bool

    static let placeholder = SettingsAccount(
        id: "default-account",
        displayName: "User",
        networkName: "Default Network",
        email: "account@example.com",
        expirationSummary: "No expiration",
        isConnected: true
    )
}
