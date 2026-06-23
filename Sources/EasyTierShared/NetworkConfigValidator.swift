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
            if forward.proto.lowercased() != "tcp", forward.proto.lowercased() != "udp" {
                issues.append("Port forward #\(index + 1) protocol must be tcp or udp.")
            }
        }

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
}
