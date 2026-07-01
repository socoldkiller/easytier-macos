import Foundation
import TOML

public enum TOMLCodecError: LocalizedError, Equatable {
    case invalidLine(String)
    case invalidValue(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidLine(line):
            "Could not parse TOML line: \(line)"
        case let .invalidValue(value):
            "Could not parse TOML value: \(value)"
        }
    }
}

public enum NetworkConfigTOMLCodec {
    public static func encode(_ config: NetworkConfig, magicDNSSettings: MagicDNSSettings? = nil) throws -> String {
        let encoder = TOMLEncoder()
        encoder.outputFormatting = [.prettyPrinted]

        let toml = try encoder.encodeToString(EasyTierTOMLDocument(config.normalized(), magicDNSSettings: magicDNSSettings))
        return toml.hasSuffix("\n") ? toml : toml + "\n"
    }

    public static func decode(_ toml: String) throws -> NetworkConfig {
        let document = try TOMLDecoder().decode(EasyTierTOMLDocument.self, from: toml)
        let config = try document.networkConfig().normalized()
        try NetworkConfigValidator.validate(config)
        return config
    }

    public static func metadata(from toml: String) throws -> NetworkConfigTOMLMetadata {
        let document = try TOMLDecoder().decode(EasyTierTOMLDocument.self, from: toml)
        return NetworkConfigTOMLMetadata(magicDNSSuffix: document.flags?.tld_dns_zone)
    }
}

public struct NetworkConfigTOMLMetadata: Equatable, Sendable {
    public var magicDNSSuffix: String?

    public init(magicDNSSuffix: String? = nil) {
        self.magicDNSSuffix = magicDNSSuffix
    }
}

private struct EasyTierTOMLDocument: Codable {
    var instance_name: String?
    var instance_id: String?
    var dhcp: Bool?
    var ipv4: String?
    var ipv6_public_addr_auto: Bool?
    var hostname: String?
    var listeners: [String]?
    var mapped_listeners: [String]?
    var routes: [String]?
    var exit_nodes: [String]?
    var mtu: Int?
    var credential_file: String?
    var socks5_proxy: String?
    var network_identity: NetworkIdentityTOML?
    var peer: [PeerTOML]?
    var proxy_network: [ProxyNetworkTOML]?
    var vpn_portal_config: VPNPortalTOML?
    var port_forward: [PortForwardTOML]?
    var flags: FlagsTOML?

    init(_ config: NetworkConfig, magicDNSSettings: MagicDNSSettings? = nil) {
        instance_name = config.network_name.isEmpty ? config.instance_id : config.network_name
        instance_id = config.instance_id
        dhcp = config.dhcp
        ipv4 = (!config.dhcp && !config.virtual_ipv4.isEmpty) ? config.virtual_ipv4 : nil
        ipv6_public_addr_auto = config.ipv6_public_addr_auto == true ? true : nil
        hostname = config.hostname?.nilIfEmpty
        listeners = config.listener_urls.nilIfEmpty
        mapped_listeners = config.mapped_listeners.nilIfEmpty
        routes = (config.enable_manual_routes && !config.routes.isEmpty) ? config.routes : nil
        exit_nodes = config.exit_nodes.nilIfEmpty
        mtu = config.mtu
        credential_file = config.credential_file?.nilIfEmpty
        socks5_proxy = config.enable_socks5 == true ? "socks5://127.0.0.1:\(config.socks5_port)" : nil
        network_identity = NetworkIdentityTOML(
            network_name: config.network_name,
            network_secret: config.network_secret ?? ""
        )
        peer = config.peer_urls.nilIfEmpty?.map { PeerTOML(uri: $0) }
        proxy_network = config.proxy_cidrs.nilIfEmpty?.map {
            ProxyNetworkTOML(cidr: $0, mapped_cidr: nil, allow: ["tcp", "udp", "icmp"])
        }
        vpn_portal_config = config.enable_vpn_portal ? VPNPortalTOML(
            client_cidr: "\(config.vpn_portal_client_network_addr)/\(config.vpn_portal_client_network_len)",
            wireguard_listen: "0.0.0.0:\(config.vpn_portal_listen_port)"
        ) : nil
        port_forward = config.port_forwards.nilIfEmpty?.map {
            PortForwardTOML(
                bind_addr: "\($0.bind_ip):\($0.bind_port)",
                dst_addr: "\($0.dst_ip):\($0.dst_port)",
                proto: $0.proto
            )
        }
        flags = FlagsTOML(config, magicDNSSettings: magicDNSSettings)
    }

    func networkConfig() throws -> NetworkConfig {
        var config = NetworkConfig()

        if let instance_id { config.instance_id = instance_id }
        if let dhcp { config.dhcp = dhcp }
        if let hostname { config.hostname = hostname }
        if let ipv6_public_addr_auto { config.ipv6_public_addr_auto = ipv6_public_addr_auto }
        if let listeners { config.listener_urls = listeners }
        if let mapped_listeners { config.mapped_listeners = mapped_listeners }
        if let routes {
            config.routes = routes
            config.enable_manual_routes = !routes.isEmpty
        }
        if let exit_nodes { config.exit_nodes = exit_nodes }
        if let mtu { config.mtu = mtu }
        if let credential_file { config.credential_file = credential_file }

        if let instance_name, config.network_name == "easytier" {
            config.network_name = instance_name
        }
        if let identity = network_identity {
            if let networkName = identity.network_name {
                config.network_name = networkName
            }
            config.network_secret = identity.network_secret ?? config.network_secret
        }

        if let ipv4 {
            try applyIPv4(ipv4, to: &config)
        }

        config.peer_urls = peer?.map(\.uri) ?? []
        config.proxy_cidrs = proxy_network?.map(\.cidr) ?? []

        if let socks5_proxy {
            guard let port = parsePort(fromProxyURL: socks5_proxy) else {
                throw TOMLCodecError.invalidValue("socks5_proxy must include a valid port.")
            }
            config.enable_socks5 = true
            config.socks5_port = port
        }

        if let vpn = vpn_portal_config {
            config.enable_vpn_portal = true
            if let client_cidr = vpn.client_cidr {
                try applyVPNClientCIDR(client_cidr, to: &config)
            } else if let client_network_addr = vpn.client_network_addr {
                config.vpn_portal_client_network_addr = client_network_addr
                config.vpn_portal_client_network_len = vpn.client_network_len ?? config.vpn_portal_client_network_len
            }
            if let wireguardListen = vpn.wireguard_listen {
                guard let port = parsePort(fromSocketAddress: wireguardListen) else {
                    throw TOMLCodecError.invalidValue("vpn_portal_config.wireguard_listen must include a valid port.")
                }
                config.vpn_portal_listen_port = port
            }
        }

        config.port_forwards = try port_forward?.enumerated().map { index, forward in
            guard let bind = parseSocketAddress(forward.bind_addr), let dst = parseSocketAddress(forward.dst_addr) else {
                throw TOMLCodecError.invalidValue("port_forward #\(index + 1) must include valid bind_addr and dst_addr socket addresses.")
            }
            return PortForwardConfig(
                bind_ip: bind.host,
                bind_port: bind.port,
                dst_ip: dst.host,
                dst_port: dst.port,
                proto: forward.proto
            )
        } ?? []

        flags?.apply(to: &config)

        return config
    }
}

private struct NetworkIdentityTOML: Codable {
    var network_name: String?
    var network_secret: String?
}

private struct PeerTOML: Codable {
    var uri: String
}

private struct ProxyNetworkTOML: Codable {
    var cidr: String
    var mapped_cidr: String?
    var allow: [String]?
}

private struct VPNPortalTOML: Codable {
    var client_cidr: String?
    var wireguard_listen: String?
    var client_network_addr: String?
    var client_network_len: Int?
}

private struct PortForwardTOML: Codable {
    var bind_addr: String
    var dst_addr: String
    var proto: String
}

private struct FlagsTOML: Codable {
    var latency_first: Bool?
    var use_smoltcp: Bool?
    var enable_ipv6: Bool?
    var enable_kcp_proxy: Bool?
    var disable_kcp_input: Bool?
    var enable_quic_proxy: Bool?
    var disable_quic_input: Bool?
    var disable_p2p: Bool?
    var p2p_only: Bool?
    var lazy_p2p: Bool?
    var bind_device: Bool?
    var no_tun: Bool?
    var enable_exit_node: Bool?
    var relay_all_peer_rpc: Bool?
    var need_p2p: Bool?
    var multi_thread: Bool?
    var proxy_forward_by_system: Bool?
    var enable_encryption: Bool?
    var disable_tcp_hole_punching: Bool?
    var disable_udp_hole_punching: Bool?
    var disable_upnp: Bool?
    var enable_udp_broadcast_relay: Bool?
    var disable_sym_hole_punching: Bool?
    var accept_dns: Bool?
    var enable_magic_dns: Bool?
    var private_mode: Bool?
    var enable_private_mode: Bool?
    var tld_dns_zone: String?
    var relay_network_whitelist: String?
    var dev_name: String?
    var instance_recv_bps_limit: Int?

    init(_ config: NetworkConfig, magicDNSSettings: MagicDNSSettings? = nil) {
        latency_first = config.latency_first
        use_smoltcp = config.use_smoltcp
        enable_ipv6 = config.disable_ipv6.map { !$0 }
        enable_kcp_proxy = config.enable_kcp_proxy
        disable_kcp_input = config.disable_kcp_input
        enable_quic_proxy = config.enable_quic_proxy
        disable_quic_input = config.disable_quic_input
        disable_p2p = config.disable_p2p
        p2p_only = config.p2p_only
        lazy_p2p = config.lazy_p2p
        bind_device = config.bind_device
        no_tun = config.no_tun
        enable_exit_node = config.enable_exit_node
        relay_all_peer_rpc = config.relay_all_peer_rpc
        need_p2p = config.need_p2p
        multi_thread = config.multi_thread
        proxy_forward_by_system = config.proxy_forward_by_system
        enable_encryption = config.disable_encryption.map { !$0 }
        disable_tcp_hole_punching = config.disable_tcp_hole_punching
        disable_udp_hole_punching = config.disable_udp_hole_punching
        disable_upnp = config.disable_upnp
        enable_udp_broadcast_relay = config.enable_udp_broadcast_relay
        disable_sym_hole_punching = config.disable_sym_hole_punching
        accept_dns = config.enable_magic_dns
        if config.enable_magic_dns == true, let magicDNSSettings {
            tld_dns_zone = magicDNSSettings.dnsSuffix
        }
        private_mode = config.enable_private_mode
        relay_network_whitelist = config.enable_relay_network_whitelist == true ? config.relay_network_whitelist.joined(separator: " ") : nil
        dev_name = config.dev_name.nilIfEmpty
        instance_recv_bps_limit = config.instance_recv_bps_limit
    }

    func apply(to config: inout NetworkConfig) {
        if let latency_first { config.latency_first = latency_first }
        if let use_smoltcp { config.use_smoltcp = use_smoltcp }
        if let enable_ipv6 { config.disable_ipv6 = !enable_ipv6 }
        if let enable_kcp_proxy { config.enable_kcp_proxy = enable_kcp_proxy }
        if let disable_kcp_input { config.disable_kcp_input = disable_kcp_input }
        if let enable_quic_proxy { config.enable_quic_proxy = enable_quic_proxy }
        if let disable_quic_input { config.disable_quic_input = disable_quic_input }
        if let disable_p2p { config.disable_p2p = disable_p2p }
        if let p2p_only { config.p2p_only = p2p_only }
        if let lazy_p2p { config.lazy_p2p = lazy_p2p }
        if let bind_device { config.bind_device = bind_device }
        if let no_tun { config.no_tun = no_tun }
        if let enable_exit_node { config.enable_exit_node = enable_exit_node }
        if let relay_all_peer_rpc { config.relay_all_peer_rpc = relay_all_peer_rpc }
        if let need_p2p { config.need_p2p = need_p2p }
        if let multi_thread { config.multi_thread = multi_thread }
        if let proxy_forward_by_system { config.proxy_forward_by_system = proxy_forward_by_system }
        if let enable_encryption { config.disable_encryption = !enable_encryption }
        if let disable_tcp_hole_punching { config.disable_tcp_hole_punching = disable_tcp_hole_punching }
        if let disable_udp_hole_punching { config.disable_udp_hole_punching = disable_udp_hole_punching }
        if let disable_upnp { config.disable_upnp = disable_upnp }
        if let enable_udp_broadcast_relay { config.enable_udp_broadcast_relay = enable_udp_broadcast_relay }
        if let disable_sym_hole_punching { config.disable_sym_hole_punching = disable_sym_hole_punching }
        if let accept_dns { config.enable_magic_dns = accept_dns }
        if let enable_magic_dns { config.enable_magic_dns = enable_magic_dns }
        if let private_mode { config.enable_private_mode = private_mode }
        if let enable_private_mode { config.enable_private_mode = enable_private_mode }
        if let relay_network_whitelist {
            config.enable_relay_network_whitelist = relay_network_whitelist != "*"
            config.relay_network_whitelist = relay_network_whitelist == "*" ? [] : relay_network_whitelist.split(separator: " ").map(String.init)
        }
        if let dev_name { config.dev_name = dev_name }
        if let instance_recv_bps_limit { config.instance_recv_bps_limit = instance_recv_bps_limit }
    }
}

private func applyIPv4(_ value: String, to config: inout NetworkConfig) throws {
    let parts = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
    guard let address = parts.first, !address.isEmpty else {
        throw TOMLCodecError.invalidValue("ipv4 must include an address.")
    }
    config.virtual_ipv4 = address
    if parts.count == 2 {
        guard let networkLength = Int(parts[1]) else {
            throw TOMLCodecError.invalidValue("ipv4 prefix must be a number.")
        }
        config.network_length = networkLength
    }
    config.dhcp = false
}

private func applyVPNClientCIDR(_ value: String, to config: inout NetworkConfig) throws {
    let parts = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
    guard let address = parts.first, !address.isEmpty else {
        throw TOMLCodecError.invalidValue("vpn_portal_config.client_cidr must include an address.")
    }
    config.vpn_portal_client_network_addr = address
    if parts.count == 2 {
        guard let networkLength = Int(parts[1]) else {
            throw TOMLCodecError.invalidValue("vpn_portal_config.client_cidr prefix must be a number.")
        }
        config.vpn_portal_client_network_len = networkLength
    }
}

private func parsePort(fromProxyURL value: String) -> Int? {
    URLComponents(string: value)?.port ?? parsePort(fromSocketAddress: value)
}

private func parsePort(fromSocketAddress value: String) -> Int? {
    if let port = URLComponents(string: "tcp://\(value)")?.port {
        return port
    }
    return Int(value.split(separator: ":").last.map(String.init) ?? "")
}

private func parseSocketAddress(_ value: String) -> (host: String, port: Int)? {
    guard let components = URLComponents(string: "tcp://\(value)"), let host = components.host, let port = components.port else {
        return nil
    }
    return (host, port)
}
