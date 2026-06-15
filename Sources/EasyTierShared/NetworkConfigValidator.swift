import Foundation

public enum NetworkConfigValidationError: LocalizedError, Equatable {
    case issues([String])

    public var errorDescription: String? {
        switch self {
        case let .issues(issues):
            issues.joined(separator: "\n")
        }
    }
}

public enum NetworkConfigValidator {
    public static func validate(_ config: NetworkConfig, activeConfigs: [NetworkConfig] = []) throws {
        var issues: [String] = []
        let normalized = config.normalized()

        if normalized.network_name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("Network name cannot be empty.")
        }

        if !normalized.dhcp {
            validateIPv4(normalized.virtual_ipv4, field: "Virtual IPv4", issues: &issues)
            validateRange(normalized.network_length, field: "Virtual IPv4 prefix", range: 1...32, issues: &issues)
        }

        validateURLs(normalized.peer_urls, field: "Initial nodes", issues: &issues)
        validateURLs(normalized.listener_urls, field: "Listeners", issues: &issues)
        validateURLs(normalized.mapped_listeners, field: "Mapped listeners", issues: &issues)
        validateCIDRs(normalized.proxy_cidrs, field: "Proxy CIDRs", issues: &issues)
        validateCIDRs(normalized.routes, field: "Routes", issues: &issues)

        if normalized.enable_vpn_portal {
            validateIPv4(normalized.vpn_portal_client_network_addr, field: "VPN client network", issues: &issues)
            validateRange(normalized.vpn_portal_client_network_len, field: "VPN client prefix", range: 1...32, issues: &issues)
            validatePort(normalized.vpn_portal_listen_port, field: "VPN portal port", issues: &issues)
        }

        if normalized.enable_socks5 == true {
            validatePort(normalized.socks5_port, field: "SOCKS5 port", issues: &issues)
        }

        for (index, forward) in normalized.port_forwards.enumerated() {
            validatePort(forward.bind_port, field: "Port forward #\(index + 1) bind port", issues: &issues)
            validatePort(forward.dst_port, field: "Port forward #\(index + 1) destination port", issues: &issues)
            validateIPv4OrWildcard(forward.bind_ip, field: "Port forward #\(index + 1) bind IP", issues: &issues)
            validateIPv4(forward.dst_ip, field: "Port forward #\(index + 1) destination IP", issues: &issues)
            if forward.proto != "tcp", forward.proto != "udp" {
                issues.append("Port forward #\(index + 1) protocol must be tcp or udp.")
            }
        }

        validatePortBindings(normalized, activeConfigs: activeConfigs, issues: &issues)

        if !issues.isEmpty {
            throw NetworkConfigValidationError.issues(issues)
        }
    }

    private static func validateURLs(_ values: [String], field: String, issues: inout [String]) {
        for value in values where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !value.contains("://") {
                issues.append("\(field) entry must include a protocol, for example tcp://host:11010.")
            }
        }
    }

    private static func validateCIDRs(_ values: [String], field: String, issues: inout [String]) {
        for value in values where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parts = value.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, let prefix = Int(parts[1]) else {
                issues.append("\(field) entry must be CIDR format, for example 10.0.0.0/24.")
                continue
            }
            validateIPv4(String(parts[0]), field: field, issues: &issues)
            validateRange(prefix, field: field + " prefix", range: 0...32, issues: &issues)
        }
    }

    private static func validateIPv4OrWildcard(_ value: String, field: String, issues: inout [String]) {
        if value == "0.0.0.0" || value.isEmpty { return }
        validateIPv4(value, field: field, issues: &issues)
    }

    private static func validateIPv4(_ value: String, field: String, issues: inout [String]) {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else {
            issues.append("\(field) must be an IPv4 address.")
            return
        }
        for part in parts {
            guard let octet = Int(part), (0...255).contains(octet) else {
                issues.append("\(field) must be an IPv4 address.")
                return
            }
        }
    }

    private static func validatePort(_ value: Int, field: String, issues: inout [String]) {
        validateRange(value, field: field, range: 1...65_535, issues: &issues)
    }

    private static func validateRange(_ value: Int, field: String, range: ClosedRange<Int>, issues: inout [String]) {
        if !range.contains(value) {
            issues.append("\(field) must be between \(range.lowerBound) and \(range.upperBound).")
        }
    }

    private static func validatePortBindings(_ config: NetworkConfig, activeConfigs: [NetworkConfig], issues: inout [String]) {
        let bindings = portBindings(for: config)
        appendPortConflicts(in: bindings, issues: &issues)

        for activeConfig in activeConfigs.map({ $0.normalized() }) where activeConfig.instance_id != config.instance_id {
            for binding in bindings {
                for activeBinding in portBindings(for: activeConfig) where binding.conflicts(with: activeBinding) {
                    issues.append(binding.conflictMessage(with: activeBinding))
                }
            }
        }
    }

    private static func appendPortConflicts(in bindings: [PortBinding], issues: inout [String]) {
        guard bindings.count > 1 else { return }
        for index in bindings.indices.dropLast() {
            for otherIndex in bindings.indices.dropFirst(index + 1) where bindings[index].conflicts(with: bindings[otherIndex]) {
                issues.append(bindings[index].conflictMessage(with: bindings[otherIndex]))
            }
        }
    }

    private static func portBindings(for config: NetworkConfig) -> [PortBinding] {
        var bindings: [PortBinding] = []
        let ownerName = config.network_name.isEmpty ? config.instance_id : config.network_name

        for listener in config.listener_urls {
            appendURLBinding(listener, label: "Listener", ownerName: ownerName, to: &bindings)
        }
        for listener in config.mapped_listeners {
            appendURLBinding(listener, label: "Mapped listener", ownerName: ownerName, to: &bindings)
        }

        if config.enable_socks5 == true, (1...65_535).contains(config.socks5_port) {
            bindings.append(
                PortBinding(
                    ownerName: ownerName,
                    label: "SOCKS5 proxy",
                    transport: .tcp,
                    host: normalizedBindHost("127.0.0.1"),
                    port: config.socks5_port
                )
            )
        }

        if config.enable_vpn_portal, (1...65_535).contains(config.vpn_portal_listen_port) {
            bindings.append(
                PortBinding(
                    ownerName: ownerName,
                    label: "VPN portal",
                    transport: .udp,
                    host: .wildcard,
                    port: config.vpn_portal_listen_port
                )
            )
        }

        for (index, forward) in config.port_forwards.enumerated() where (1...65_535).contains(forward.bind_port) {
            guard let transport = LocalPortTransport(rawValue: forward.proto.lowercased()) else { continue }
            bindings.append(
                PortBinding(
                    ownerName: ownerName,
                    label: "Port forward #\(index + 1)",
                    transport: transport,
                    host: normalizedBindHost(forward.bind_ip),
                    port: forward.bind_port
                )
            )
        }

        return bindings
    }

    private static func appendURLBinding(_ value: String, label: String, ownerName: String, to bindings: inout [PortBinding]) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let transport = transport(forScheme: scheme),
              let port = components.port ?? defaultPort(forScheme: scheme),
              port > 0,
              port <= 65_535
        else { return }

        bindings.append(
            PortBinding(
                ownerName: ownerName,
                label: "\(label) \(trimmed)",
                transport: transport,
                host: normalizedBindHost(components.host ?? ""),
                port: port
            )
        )
    }

    private static func transport(forScheme scheme: String) -> LocalPortTransport? {
        switch scheme {
        case "tcp", "ws", "wss", "faketcp", "http", "https", "socks5":
            .tcp
        case "udp", "wg", "quic", "kcp":
            .udp
        default:
            nil
        }
    }

    private static func defaultPort(forScheme scheme: String) -> Int? {
        switch scheme {
        case "tcp", "udp": 11_010
        case "wg": 11_011
        case "quic": 11_012
        case "faketcp": 11_013
        case "ws", "http": 80
        case "wss", "https": 443
        default: nil
        }
    }

    private static func normalizedBindHost(_ value: String) -> BindHost {
        let host = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()

        if host.isEmpty || host == "*" || host == "0.0.0.0" || host == "::" {
            return .wildcard
        }
        return .host(host)
    }
}

private enum LocalPortTransport: String {
    case tcp
    case udp

    var label: String { rawValue.uppercased() }
}

private enum BindHost: Equatable {
    case wildcard
    case host(String)

    var label: String {
        switch self {
        case .wildcard:
            "0.0.0.0"
        case let .host(host):
            host
        }
    }

    func overlaps(_ other: BindHost) -> Bool {
        switch (self, other) {
        case (.wildcard, _), (_, .wildcard):
            true
        case let (.host(lhs), .host(rhs)):
            lhs == rhs
        }
    }
}

private struct PortBinding {
    var ownerName: String
    var label: String
    var transport: LocalPortTransport
    var host: BindHost
    var port: Int

    func conflicts(with other: PortBinding) -> Bool {
        transport == other.transport && port == other.port && host.overlaps(other.host)
    }

    func conflictMessage(with other: PortBinding) -> String {
        "Port conflict: \(ownerName) \(label) and \(other.ownerName) \(other.label) both bind \(transport.label) \(host.label):\(port)."
    }
}
