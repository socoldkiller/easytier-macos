struct SettingsAccount: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let networkName: String
    let username: String
    let configEndpoint: String
    let statusSummary: String
    let isConnected: Bool
}
