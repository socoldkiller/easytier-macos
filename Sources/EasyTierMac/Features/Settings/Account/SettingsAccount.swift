import EasyTierShared

struct SettingsAccount: Identifiable, Hashable, Sendable {
    let id: RemoteAccountID
    let displayName: String
    let serverName: String
    let username: String
    let version: String
    let publicIPAddress: String
    let hostname: String
    let statusSummary: String
    let isConnected: Bool
    let isActive: Bool
    let hasCredential: Bool
}
