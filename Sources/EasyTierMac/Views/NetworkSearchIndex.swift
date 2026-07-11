import EasyTierShared

enum NetworkSearchIndex {
    static func results(
        matching query: SearchQuery,
        configs: [NetworkConfig],
        instanceForConfig: (NetworkConfig) -> NetworkInstance?,
        connectionStateForConfig: (NetworkConfig) -> ConnectionGlyphState
    ) -> [NetworkSearchResult] {
        guard !query.isEmpty else { return [] }

        return configs.flatMap { config -> [NetworkSearchResult] in
            let instance = instanceForConfig(config)
            let connectionState = connectionStateForConfig(config)
            var results: [NetworkSearchResult] = []

            let networkFields = networkFields(
                for: config,
                instance: instance,
                connectionState: connectionState
            )
            if query.matches(networkFields.searchValues) {
                results.append(.network(
                    id: "network-\(config.id)",
                    networkID: config.id,
                    title: config.network_name,
                    subtitle: networkSubtitle(connectionState: connectionState, instance: instance),
                    state: connectionState,
                    matchDescription: matchDescription(in: networkFields, query: query)
                ))
            }

            for member in instance?.detail?.memberStatuses ?? [] {
                let fields = memberFields(for: member)
                guard query.matches(fields.searchValues) else { continue }

                results.append(.device(
                    id: "device-\(config.id)-\(member.id)",
                    networkID: config.id,
                    title: member.hostname,
                    subtitle: memberSubtitle(member, networkName: config.network_name),
                    sourceLabel: "Device",
                    matchDescription: matchDescription(in: fields, query: query),
                    systemImage: member.searchResultSystemImage,
                    targetTab: .status,
                    highlightedPeerID: member.peerID
                ))
            }

            return results
        }
    }

    private static func networkFields(
        for config: NetworkConfig,
        instance: NetworkInstance?,
        connectionState: ConnectionGlyphState
    ) -> [SearchResultField] {
        var fields: [SearchResultField] = [
            SearchResultField("Network", config.network_name),
            SearchResultField("Instance ID", config.instance_id),
            SearchResultField(
                "Status",
                connectionState.searchLabel,
                displayValue: connectionState.displayLabel
            ),
            SearchResultField("Runtime", instance?.name ?? ""),
            SearchResultField("Runtime ID", instance?.instance_id ?? ""),
            SearchResultField("Device", instance?.detail?.dev_name ?? ""),
            SearchResultField("Error", instance?.detail?.error_msg ?? ""),
            SearchResultField("Hostname", config.hostname ?? ""),
            SearchResultField("Virtual IPv4", config.virtual_ipv4),
            SearchResultField("Network Length", String(config.network_length)),
            SearchResultField("Public Server", config.public_server_url),
            SearchResultField("Device Name", config.dev_name),
            SearchResultField("VPN Portal", config.vpn_portal_client_network_addr),
            SearchResultField("VPN Portal Port", String(config.vpn_portal_listen_port)),
            SearchResultField("VPN Portal Length", String(config.vpn_portal_client_network_len)),
            SearchResultField("SOCKS5 Port", String(config.socks5_port)),
            SearchResultField(
                "Mode",
                config.networking_method.searchLabel,
                displayValue: config.networking_method.displayLabel
            ),
        ]
        fields.append(contentsOf: config.peer_urls.map { SearchResultField("Peer URL", $0) })
        fields.append(contentsOf: config.listener_urls.map { SearchResultField("Listener", $0) })
        fields.append(contentsOf: config.proxy_cidrs.map { SearchResultField("Proxy CIDR", $0) })
        fields.append(contentsOf: config.routes.map { SearchResultField("Route", $0) })
        fields.append(contentsOf: config.exit_nodes.map { SearchResultField("Exit Node", $0) })
        fields.append(contentsOf: config.mapped_listeners.map { SearchResultField("Mapped Listener", $0) })
        fields.append(contentsOf: config.relay_network_whitelist.map { SearchResultField("Relay Whitelist", $0) })
        fields.append(contentsOf: config.enabledSearchFeatureLabels.map { SearchResultField("Feature", $0) })
        for portForward in config.port_forwards {
            fields.append(contentsOf: [
                SearchResultField("Port Forward Bind IP", portForward.bind_ip),
                SearchResultField("Port Forward Bind Port", String(portForward.bind_port)),
                SearchResultField("Port Forward Target IP", portForward.dst_ip),
                SearchResultField("Port Forward Target Port", String(portForward.dst_port)),
                SearchResultField("Port Forward Protocol", portForward.proto),
                SearchResultField("Feature", "port forward forwarding", displayValue: "Port Forward"),
            ])
        }
        return fields
    }

    private static func memberFields(for member: NetworkMemberStatus) -> [SearchResultField] {
        var fields = [
            SearchResultField("Hostname", member.hostname),
            SearchResultField("Virtual IPv4", member.virtualIPv4),
            SearchResultField("IPv4", member.copyableIPv4Address ?? ""),
            SearchResultField("Version", member.version),
            SearchResultField("Route Cost", member.routeCost),
            SearchResultField("Protocol", member.tunnelProto),
            SearchResultField("Latency", member.latency),
            SearchResultField("Upload", member.uploadTotal),
            SearchResultField("Download", member.downloadTotal),
            SearchResultField("Loss", member.lossRate),
            SearchResultField("NAT", member.natType),
            SearchResultField(
                "Role",
                member.isLocal ? "local this device self" : "remote peer device",
                displayValue: member.isLocal ? "This Device" : "Remote Device"
            ),
        ]

        switch member.availability {
        case .online:
            fields.append(SearchResultField("Status", "online connected", displayValue: "Online"))
        case .connecting:
            fields.append(SearchResultField("Status", "connecting reconnecting loading", displayValue: "Connecting"))
        case .assigningAddress:
            fields.append(SearchResultField("Status", "assigning ip address loading starting", displayValue: "Assigning IP"))
        }
        if member.isPublicServer {
            fields.append(SearchResultField("Role", "public server public servers server relay", displayValue: "Public Server"))
        }
        return fields
    }

    private static func matchDescription(in fields: [SearchResultField], query: SearchQuery) -> String? {
        let matches = fields.matchingTokens(from: query)
        guard !matches.isEmpty else { return nil }
        let summary = matches.prefix(2)
            .map { "\($0.label.lowercased()): \($0.displayValue)" }
            .joined(separator: " · ")
        return "Matched \(summary)"
    }

    private static func networkSubtitle(
        connectionState: ConnectionGlyphState,
        instance: NetworkInstance?
    ) -> String {
        [connectionState.displayLabel, instance?.detail?.dev_name]
            .compactMap { $0?.nilIfEmpty }
            .joined(separator: " · ")
    }

    private static func memberSubtitle(_ member: NetworkMemberStatus, networkName: String) -> String {
        var parts = ["Network \(networkName)"]
        if let ip = member.copyableIPv4Address {
            parts.append("IPv4 \(ip)")
        }
        if member.isPublicServer {
            parts.append("Public Server")
        }
        return parts.joined(separator: " · ")
    }
}
