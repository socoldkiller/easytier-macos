import EasyTierShared

extension NetworkMemberStatus {
    func searchFields(alias: DeviceAlias?) -> [String] {
        var fields = [
            alias?.displayName ?? "",
            alias?.hostname ?? "",
            alias?.peerID ?? "",
            hostname,
            peerID,
            virtualIPv4,
            copyableIPv4Address ?? "",
            version,
            routeCost,
            tunnelProto,
            latency,
            uploadTotal,
            downloadTotal,
            lossRate,
            natType,
            isLocal ? "local this device self" : "online remote peer device",
        ]

        if isPublicServer {
            fields.append("public server public servers server relay")
        }

        return fields
    }

    var searchResultSystemImage: String {
        if isLocal { return "macbook" }
        if isPublicServer { return "server.rack" }
        return "desktopcomputer"
    }
}

extension ConnectionGlyphState {
    var searchLabel: String {
        switch self {
        case .idle:
            return "idle stopped disconnected"
        case .connecting:
            return "connecting working starting"
        case .connected:
            return "connected running online"
        case .error:
            return "error failed warning"
        }
    }

    var displayLabel: String {
        switch self {
        case .idle:
            return "Stopped"
        case .connecting:
            return "Connecting"
        case .connected:
            return "Running"
        case .error:
            return "Error"
        }
    }
}

extension NetworkingMethod {
    var searchLabel: String {
        switch self {
        case .publicServer:
            return "public server public relay"
        case .manual:
            return "manual peer peers"
        case .standalone:
            return "standalone local"
        }
    }
}

extension String {
    var nilIfEmptyForSearchResult: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension NetworkConfig {
    var enabledSearchFeatureLabels: [String] {
        var labels: [String] = []
        if dhcp { labels.append("dhcp") }
        if enable_vpn_portal { labels.append("vpn portal") }
        if enable_socks5 == true { labels.append("socks socks5 proxy") }
        if enable_exit_node == true { labels.append("exit node") }
        if enable_magic_dns == true { labels.append("magic dns") }
        if enable_private_mode == true { labels.append("private mode") }
        if no_tun == true { labels.append("no tun") }
        if disable_p2p == true { labels.append("disable p2p relay only") }
        if enable_manual_routes { labels.append("manual routes routing") }
        return labels
    }
}
