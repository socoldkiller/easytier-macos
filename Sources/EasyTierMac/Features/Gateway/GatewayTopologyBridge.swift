import EasyTierShared
import Foundation

@MainActor
enum GatewayTopologyBridge {
    static func fingerprint(
        gateway: GatewayRuntimeController,
        store: EasyTierAppStore
    ) -> String {
        guard let topology = topology(gateway: gateway, store: store) else { return "none" }
        let memberFingerprint = topology.members
            .filter(\.isLive)
            .map { "\($0.peerID):\($0.hostname)" }
            .sorted()
            .joined(separator: "|")
        return [
            topology.config.instance_id,
            runtimeIPv4CIDR(config: topology.config, detail: topology.detail) ?? "-",
            store.magicDNSSettings.dnsSuffix,
            memberFingerprint,
        ].joined(separator: "::")
    }

    static func reconcile(
        gateway: GatewayRuntimeController,
        store: EasyTierAppStore
    ) async {
        guard let topology = topology(gateway: gateway, store: store) else { return }
        var hostnamesByPeerID: [String: String] = [:]
        for member in topology.members where member.isLive {
            guard hasStablePeerID(member.peerID) else { continue }
            hostnamesByPeerID[member.peerID] = member.hostname
        }
        await gateway.reconcileTopology(
            networkConfigID: topology.config.instance_id,
            allowedIPv4CIDR: runtimeIPv4CIDR(config: topology.config, detail: topology.detail),
            magicDNSSuffix: store.magicDNSSettings.dnsSuffix,
            hostnamesByPeerID: hostnamesByPeerID
        )
    }

    static func canPublish(_ member: NetworkMemberStatus, store: EasyTierAppStore) -> Bool {
        guard member.isLive,
              hasStablePeerID(member.peerID),
              store.selectedConfig?.enable_magic_dns == true
        else { return false }
        return MagicDNSDisplay.memberDomain(
            hostname: member.hostname,
            config: store.selectedConfig,
            settings: store.magicDNSSettings
        ) != nil
    }

    static func networkName(
        for networkConfigID: String?,
        store: EasyTierAppStore
    ) -> String {
        guard let networkConfigID,
              let config = store.configs.first(where: { $0.instance_id == networkConfigID })
        else { return "Unavailable" }
        return config.network_name
    }

    static func members(
        for networkConfigID: String?,
        store: EasyTierAppStore
    ) -> [NetworkMemberStatus] {
        guard let networkConfigID,
              let config = store.configs.first(where: { $0.instance_id == networkConfigID })
        else { return [] }
        let instance = store.runningInstance(matching: config)
        let detail = instance.flatMap { store.runtimeDetails[$0.name] ?? $0.detail }
        if store.selectedConfig?.instance_id == networkConfigID {
            return store.selectedStatusSnapshot.members
        }
        return detail?.memberStatuses ?? []
    }

    private static func topology(
        gateway: GatewayRuntimeController,
        store: EasyTierAppStore
    ) -> (config: NetworkConfig, detail: NetworkInstanceRunningInfo?, members: [NetworkMemberStatus])? {
        let configID = gateway.publishingNetworkConfigID ?? store.selectedConfig?.instance_id
        guard let configID,
              let config = store.configs.first(where: { $0.instance_id == configID })
        else { return nil }
        let instance = store.runningInstance(matching: config)
        let detail = instance.flatMap { store.runtimeDetails[$0.name] ?? $0.detail }
        let members = store.selectedConfig?.instance_id == configID
            ? store.selectedStatusSnapshot.members
            : detail?.memberStatuses ?? []
        return (config, detail, members)
    }

    private static func runtimeIPv4CIDR(
        config: NetworkConfig,
        detail: NetworkInstanceRunningInfo?
    ) -> String? {
        if let runtimeAddress = detail?
            .my_node_info?
            .virtual_ipv4?
            .displayString
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !runtimeAddress.isEmpty
        {
            return runtimeAddress
        }
        if let runtimeAddress = detail?
            .my_node_info?
            .ipv4_addr?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !runtimeAddress.isEmpty
        {
            return runtimeAddress
        }
        let address = config.virtual_ipv4.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return nil }
        return address.contains("/") ? address : "\(address)/\(config.network_length)"
    }

    private static func hasStablePeerID(_ peerID: String) -> Bool {
        let peerID = peerID.trimmingCharacters(in: .whitespacesAndNewlines)
        return !peerID.isEmpty && peerID != "-" && peerID != "local"
    }
}
