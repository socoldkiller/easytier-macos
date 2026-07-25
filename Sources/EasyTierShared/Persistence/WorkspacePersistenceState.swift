import Foundation

package struct WorkspacePersistenceState: Equatable, Sendable {
    package var configs: [NetworkConfig]
    package var selectedConfigID: String?
    package var mode: AppMode
    package var vpnOnDemandEnabled: Bool
    package var runtimeIntents: [RuntimeIntent]
    package var reversedPortForwardFingerprints: [String: Set<String>]
    package var magicDNSSettings: MagicDNSSettings
    package var peerSubscriptions: [PeerSubscription]

    package init(
        configs: [NetworkConfig],
        selectedConfigID: String?,
        mode: AppMode = .default,
        vpnOnDemandEnabled: Bool = false,
        runtimeIntents: [RuntimeIntent] = [],
        reversedPortForwardFingerprints: [String: Set<String>] = [:],
        magicDNSSettings: MagicDNSSettings = .default,
        peerSubscriptions: [PeerSubscription] = []
    ) {
        self.configs = configs
        self.selectedConfigID = selectedConfigID
        self.mode = mode
        self.vpnOnDemandEnabled = vpnOnDemandEnabled
        self.runtimeIntents = runtimeIntents
        self.reversedPortForwardFingerprints = reversedPortForwardFingerprints
        self.magicDNSSettings = magicDNSSettings
        self.peerSubscriptions = peerSubscriptions
    }

    package static func defaultState() -> WorkspacePersistenceState {
        let config = NetworkConfig()
        return WorkspacePersistenceState(configs: [config], selectedConfigID: config.id)
    }
}
