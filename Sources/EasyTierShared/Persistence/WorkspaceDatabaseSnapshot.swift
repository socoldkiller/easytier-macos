struct WorkspaceDatabaseSnapshot: Sendable {
    var settings: WorkspaceSettingsRecord
    var configs: [NetworkConfigRecord]
    var runtimeIntents: [RuntimeIntentRecord]
    var fingerprints: [ReversedPortForwardFingerprintRecord]
    var subscriptions: [PeerSubscriptionRecord]
    var cards: [PeerCardRecord]
    var cardURLs: [PeerCardURLRecord]
}
