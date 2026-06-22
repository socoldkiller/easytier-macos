import Foundation
import SystemConfiguration

public enum NetworkingMethod: Int, Codable, CaseIterable, Identifiable, Sendable {
    case publicServer = 0
    case manual = 1
    case standalone = 2

    public var id: Int { rawValue }
}

public struct PortForwardConfig: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var bind_ip: String
    public var bind_port: Int
    public var dst_ip: String
    public var dst_port: Int
    public var proto: String

    enum CodingKeys: String, CodingKey {
        case bind_ip, bind_port, dst_ip, dst_port, proto
    }

    public static func == (lhs: PortForwardConfig, rhs: PortForwardConfig) -> Bool {
        lhs.bind_ip == rhs.bind_ip
            && lhs.bind_port == rhs.bind_port
            && lhs.dst_ip == rhs.dst_ip
            && lhs.dst_port == rhs.dst_port
            && lhs.proto == rhs.proto
    }

    public init(bind_ip: String = "", bind_port: Int = 65_535, dst_ip: String = "", dst_port: Int = 65_535, proto: String = "tcp") {
        self.bind_ip = bind_ip
        self.bind_port = bind_port
        self.dst_ip = dst_ip
        self.dst_port = dst_port
        self.proto = proto
    }
}

public enum ListenerURLDefaults {
    public static let addSuggestions = [
        "tcp://0.0.0.0:11010",
        "udp://0.0.0.0:11010",
        "wg://0.0.0.0:11011",
        "ws://0.0.0.0:11011",
        "wss://0.0.0.0:11012",
        "quic://0.0.0.0:11012",
        "faketcp://0.0.0.0:11013",
    ]

    public static func next(excluding existing: [String]) -> String {
        let existing = Set(existing.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        return addSuggestions.first { !existing.contains($0) } ?? ""
    }
}

public struct NetworkConfig: Codable, Equatable, Identifiable, Sendable {
    public var id: String { instance_id }

    public var instance_id: String
    public var dhcp: Bool
    public var virtual_ipv4: String
    public var network_length: Int
    public var hostname: String?
    public var network_name: String
    public var network_secret: String?
    public var credential_file: String?
    public var networking_method: NetworkingMethod
    public var public_server_url: String
    public var peer_urls: [String]
    public var proxy_cidrs: [String]
    public var enable_vpn_portal: Bool
    public var vpn_portal_listen_port: Int
    public var vpn_portal_client_network_addr: String
    public var vpn_portal_client_network_len: Int
    public var advanced_settings: Bool
    public var listener_urls: [String]
    public var latency_first: Bool
    public var dev_name: String
    public var use_smoltcp: Bool?
    public var disable_ipv6: Bool?
    public var ipv6_public_addr_auto: Bool?
    public var enable_kcp_proxy: Bool?
    public var disable_kcp_input: Bool?
    public var enable_quic_proxy: Bool?
    public var disable_quic_input: Bool?
    public var disable_p2p: Bool?
    public var p2p_only: Bool?
    public var lazy_p2p: Bool?
    public var bind_device: Bool?
    public var no_tun: Bool?
    public var enable_exit_node: Bool?
    public var relay_all_peer_rpc: Bool?
    public var need_p2p: Bool?
    public var multi_thread: Bool?
    public var proxy_forward_by_system: Bool?
    public var disable_encryption: Bool?
    public var disable_tcp_hole_punching: Bool?
    public var disable_udp_hole_punching: Bool?
    public var disable_upnp: Bool?
    public var enable_udp_broadcast_relay: Bool?
    public var disable_sym_hole_punching: Bool?
    public var enable_relay_network_whitelist: Bool?
    public var relay_network_whitelist: [String]
    public var enable_manual_routes: Bool
    public var routes: [String]
    public var exit_nodes: [String]
    public var enable_socks5: Bool?
    public var socks5_port: Int
    public var mtu: Int?
    public var instance_recv_bps_limit: Int?
    public var mapped_listeners: [String]
    public var enable_magic_dns: Bool?
    public var enable_private_mode: Bool?
    public var port_forwards: [PortForwardConfig]

    public init(
        instance_id: String = UUID().uuidString.lowercased(),
        dhcp: Bool = true,
        virtual_ipv4: String = "",
        network_length: Int = 24,
        hostname: String? = nil,
        network_name: String = "easytier",
        network_secret: String? = "",
        credential_file: String? = "",
        networking_method: NetworkingMethod = .manual,
        public_server_url: String = "",
        peer_urls: [String] = [],
        proxy_cidrs: [String] = [],
        enable_vpn_portal: Bool = false,
        vpn_portal_listen_port: Int = 22_022,
        vpn_portal_client_network_addr: String = "",
        vpn_portal_client_network_len: Int = 24,
        advanced_settings: Bool = false,
        listener_urls: [String] = ["tcp://0.0.0.0:11010", "udp://0.0.0.0:11010", "wg://0.0.0.0:11011"],
        latency_first: Bool = false,
        dev_name: String = "",
        use_smoltcp: Bool? = false,
        disable_ipv6: Bool? = false,
        ipv6_public_addr_auto: Bool? = false,
        enable_kcp_proxy: Bool? = false,
        disable_kcp_input: Bool? = false,
        enable_quic_proxy: Bool? = false,
        disable_quic_input: Bool? = false,
        disable_p2p: Bool? = false,
        p2p_only: Bool? = false,
        lazy_p2p: Bool? = false,
        bind_device: Bool? = true,
        no_tun: Bool? = false,
        enable_exit_node: Bool? = false,
        relay_all_peer_rpc: Bool? = false,
        need_p2p: Bool? = false,
        multi_thread: Bool? = true,
        proxy_forward_by_system: Bool? = false,
        disable_encryption: Bool? = false,
        disable_tcp_hole_punching: Bool? = false,
        disable_udp_hole_punching: Bool? = false,
        disable_upnp: Bool? = false,
        enable_udp_broadcast_relay: Bool? = false,
        disable_sym_hole_punching: Bool? = false,
        enable_relay_network_whitelist: Bool? = false,
        relay_network_whitelist: [String] = [],
        enable_manual_routes: Bool = false,
        routes: [String] = [],
        exit_nodes: [String] = [],
        enable_socks5: Bool? = false,
        socks5_port: Int = 1_080,
        mtu: Int? = nil,
        instance_recv_bps_limit: Int? = nil,
        mapped_listeners: [String] = [],
        enable_magic_dns: Bool? = false,
        enable_private_mode: Bool? = false,
        port_forwards: [PortForwardConfig] = []
    ) {
        self.instance_id = instance_id
        self.dhcp = dhcp
        self.virtual_ipv4 = virtual_ipv4
        self.network_length = network_length
        self.hostname = hostname
        self.network_name = network_name
        self.network_secret = network_secret
        self.credential_file = credential_file
        self.networking_method = networking_method
        self.public_server_url = public_server_url
        self.peer_urls = peer_urls
        self.proxy_cidrs = proxy_cidrs
        self.enable_vpn_portal = enable_vpn_portal
        self.vpn_portal_listen_port = vpn_portal_listen_port
        self.vpn_portal_client_network_addr = vpn_portal_client_network_addr
        self.vpn_portal_client_network_len = vpn_portal_client_network_len
        self.advanced_settings = advanced_settings
        self.listener_urls = listener_urls
        self.latency_first = latency_first
        self.dev_name = dev_name
        self.use_smoltcp = use_smoltcp
        self.disable_ipv6 = disable_ipv6
        self.ipv6_public_addr_auto = ipv6_public_addr_auto
        self.enable_kcp_proxy = enable_kcp_proxy
        self.disable_kcp_input = disable_kcp_input
        self.enable_quic_proxy = enable_quic_proxy
        self.disable_quic_input = disable_quic_input
        self.disable_p2p = disable_p2p
        self.p2p_only = p2p_only
        self.lazy_p2p = lazy_p2p
        self.bind_device = bind_device
        self.no_tun = no_tun
        self.enable_exit_node = enable_exit_node
        self.relay_all_peer_rpc = relay_all_peer_rpc
        self.need_p2p = need_p2p
        self.multi_thread = multi_thread
        self.proxy_forward_by_system = proxy_forward_by_system
        self.disable_encryption = disable_encryption
        self.disable_tcp_hole_punching = disable_tcp_hole_punching
        self.disable_udp_hole_punching = disable_udp_hole_punching
        self.disable_upnp = disable_upnp
        self.enable_udp_broadcast_relay = enable_udp_broadcast_relay
        self.disable_sym_hole_punching = disable_sym_hole_punching
        self.enable_relay_network_whitelist = enable_relay_network_whitelist
        self.relay_network_whitelist = relay_network_whitelist
        self.enable_manual_routes = enable_manual_routes
        self.routes = routes
        self.exit_nodes = exit_nodes
        self.enable_socks5 = enable_socks5
        self.socks5_port = socks5_port
        self.mtu = mtu
        self.instance_recv_bps_limit = instance_recv_bps_limit
        self.mapped_listeners = mapped_listeners
        self.enable_magic_dns = enable_magic_dns
        self.enable_private_mode = enable_private_mode
        self.port_forwards = port_forwards
    }

    public func normalized() -> NetworkConfig {
        var copy = self
        copy.peer_urls = peer_urls.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let publicServerURL = public_server_url.trimmingCharacters(in: .whitespacesAndNewlines)

        switch networking_method {
        case .publicServer:
            copy.peer_urls = publicServerURL.isEmpty ? [] : [publicServerURL]
        case .manual:
            break
        case .standalone:
            copy.peer_urls = []
        }

        copy.networking_method = .manual
        copy.public_server_url = ""
        return copy
    }
}

public extension NetworkConfig {
    var expectsRemotePeerConnection: Bool {
        switch networking_method {
        case .standalone:
            return false
        case .publicServer:
            return !public_server_url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .manual:
            return peer_urls.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
    }
}

public enum HostProxyCIDR {
    public static func first(excluding existing: [String] = []) -> String {
        let existing = Set(existing.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        return cidrs(from: hostIPv4Interfaces(), primaryInterface: primaryIPv4Interface()).first { !existing.contains($0) } ?? ""
    }

    static func cidrs(from interfaces: [(name: String, address: UInt32, netmask: UInt32)], primaryInterface: String?) -> [String] {
        interfaces
            .sorted { lhs, rhs in lhs.name == primaryInterface && rhs.name != primaryInterface }
            .map { cidr(address: $0.address, netmask: $0.netmask) }
    }

    static func cidr(address: UInt32, netmask: UInt32) -> String {
        "\(ipv4String(address & netmask))/\(netmask.nonzeroBitCount)"
    }

    private static func hostIPv4Interfaces() -> [(name: String, address: UInt32, netmask: UInt32)] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return [] }
        defer { freeifaddrs(head) }

        var interfaces: [(name: String, address: UInt32, netmask: UInt32)] = []
        var item: UnsafeMutablePointer<ifaddrs>? = head
        while let current = item {
            defer { item = current.pointee.ifa_next }

            let flags = current.pointee.ifa_flags
            guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_LOOPBACK) == 0, flags & UInt32(IFF_POINTOPOINT) == 0 else { continue }
            guard let addr = current.pointee.ifa_addr, let netmask = current.pointee.ifa_netmask else { continue }
            guard addr.pointee.sa_family == UInt8(AF_INET), netmask.pointee.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: current.pointee.ifa_name)
            let address = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            interfaces.append((name, address, mask))
        }
        return interfaces
    }

    private static func primaryIPv4Interface() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "EasyTier" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else { return nil }
        return value["PrimaryInterface"] as? String
    }

    private static func ipv4String(_ value: UInt32) -> String {
        [24, 16, 8, 0].map { String((value >> UInt32($0)) & 0xff) }.joined(separator: ".")
    }
}

public struct NetworkInstance: Codable, Identifiable, Equatable, Sendable {
    public var id: String { instance_id }
    public var instance_id: String
    public var name: String
    public var running: Bool
    public var error_msg: String
    public var detail: NetworkInstanceRunningInfo?

    public init(instance_id: String, name: String, running: Bool = false, error_msg: String = "", detail: NetworkInstanceRunningInfo? = nil) {
        self.instance_id = instance_id
        self.name = name
        self.running = running
        self.error_msg = error_msg
        self.detail = detail
    }
}

public extension NetworkInstance {
    var runtimeErrorMessage: String? {
        if let error = error_msg.nilIfEmpty { return error }
        if let error = detail?.error_msg?.nilIfEmpty { return error }
        return nil
    }

    var isFullyConnected: Bool {
        isFullyConnected(expectRemotePeers: false)
    }

    func isFullyConnected(expectRemotePeers: Bool) -> Bool {
        guard running, runtimeErrorMessage == nil else { return false }
        return detail?.isFullyConnected(expectRemotePeers: expectRemotePeers) == true
    }
}

public struct NetworkInstanceRunningInfo: Codable, Equatable, Sendable {
    public var dev_name: String?
    public var my_node_info: NodeInfo?
    public var events: [String]?
    public var routes: [Route]?
    public var peers: [PeerInfo]?
    public var peer_route_pairs: [PeerRoutePair]?
    public var running: Bool?
    public var error_msg: String?

    enum CodingKeys: String, CodingKey {
        case dev_name, my_node_info, events, routes, peers, peer_route_pairs, running, error_msg
    }

    public init(
        dev_name: String? = nil,
        my_node_info: NodeInfo? = nil,
        events: [String]? = nil,
        routes: [Route]? = nil,
        peers: [PeerInfo]? = nil,
        peer_route_pairs: [PeerRoutePair]? = nil,
        running: Bool? = nil,
        error_msg: String? = nil
    ) {
        self.dev_name = dev_name
        self.my_node_info = my_node_info
        self.events = events
        self.routes = routes
        self.peers = peers
        self.peer_route_pairs = peer_route_pairs
        self.running = running
        self.error_msg = error_msg
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dev_name = try container.decodeIfPresent(String.self, forKey: .dev_name)
        my_node_info = try container.decodeIfPresent(NodeInfo.self, forKey: .my_node_info)
        events = try container.decodeIfPresent([String].self, forKey: .events)
        routes = try container.decodeLossyArray(Route.self, forKey: .routes)
        peers = try container.decodeLossyArray(PeerInfo.self, forKey: .peers)
        peer_route_pairs = try container.decodeLossyArray(PeerRoutePair.self, forKey: .peer_route_pairs)
        running = try container.decodeIfPresent(Bool.self, forKey: .running)
        error_msg = try container.decodeIfPresent(String.self, forKey: .error_msg)
    }
}

public struct NodeInfo: Codable, Equatable, Sendable {
    public var ipv4_addr: String?
    public var virtual_ipv4: IPv4InetValue?
    public var hostname: String?
    public var version: String?
    public var peer_id: Int?
    public var listeners: [URLValue]?
    public var stun_info: StunInfo?
    public var vpn_portal_cfg: String?
    public var feature_flag: PeerFeatureFlag?

    enum CodingKeys: String, CodingKey {
        case ipv4_addr, virtual_ipv4, hostname, version, peer_id, listeners, stun_info, vpn_portal_cfg, feature_flag
    }

    public init(
        ipv4_addr: String? = nil,
        virtual_ipv4: IPv4InetValue? = nil,
        hostname: String? = nil,
        version: String? = nil,
        peer_id: Int? = nil,
        listeners: [URLValue]? = nil,
        stun_info: StunInfo? = nil,
        vpn_portal_cfg: String? = nil,
        feature_flag: PeerFeatureFlag? = nil
    ) {
        self.ipv4_addr = ipv4_addr
        self.virtual_ipv4 = virtual_ipv4
        self.hostname = hostname
        self.version = version
        self.peer_id = peer_id
        self.listeners = listeners
        self.stun_info = stun_info
        self.vpn_portal_cfg = vpn_portal_cfg
        self.feature_flag = feature_flag
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        ipv4_addr = try container.decodeStringIfPresent("ipv4_addr", "ipv4Addr")
        virtual_ipv4 = try container.decodeIfPresent(IPv4InetValue.self, forKeys: "virtual_ipv4", "virtualIpv4")
        hostname = try container.decodeStringIfPresent("hostname")
        version = try container.decodeStringIfPresent("version")
        peer_id = container.decodeFlexibleInt(forKeys: "peer_id", "peerId")
        listeners = try container.decodeLossyArray(URLValue.self, forKeys: "listeners")
        stun_info = try container.decodeIfPresent(StunInfo.self, forKeys: "stun_info", "stunInfo")
        vpn_portal_cfg = try container.decodeStringIfPresent("vpn_portal_cfg", "vpnPortalCfg")
        feature_flag = try container.decodeIfPresent(PeerFeatureFlag.self, forKeys: "feature_flag", "featureFlag")
    }
}

public struct PeerFeatureFlag: Codable, Equatable, Sendable {
    public var is_public_server: Bool?

    enum CodingKeys: String, CodingKey {
        case is_public_server
    }

    public init(is_public_server: Bool? = nil) {
        self.is_public_server = is_public_server
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        is_public_server = try container.decodeBoolIfPresent("is_public_server", "isPublicServer")
    }
}

public struct IPv4AddressValue: Codable, Equatable, Sendable {
    public var addr: Int64?

    enum CodingKeys: String, CodingKey {
        case addr
    }

    public init(addr: Int64? = nil) {
        self.addr = addr
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        addr = container.decodeFlexibleInt64(forKey: .addr)
    }
}

public struct IPv4InetValue: Codable, Equatable, Sendable {
    public var rawValue: String?
    public var address: IPv4AddressValue?
    public var network_length: Int?

    enum CodingKeys: String, CodingKey {
        case address, network_length
    }

    public init(rawValue: String? = nil, address: IPv4AddressValue? = nil, network_length: Int? = nil) {
        self.rawValue = rawValue
        self.address = address
        self.network_length = network_length
    }

    public init(from decoder: Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(String.self) {
            rawValue = value
            address = nil
            network_length = nil
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        rawValue = nil
        address = try container.decodeIfPresent(IPv4AddressValue.self, forKey: .address)
        network_length = try container.decodeIfPresent(Int.self, forKey: .network_length)
    }

    public func encode(to encoder: Encoder) throws {
        if let rawValue {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
            return
        }

        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(address, forKey: .address)
        try container.encodeIfPresent(network_length, forKey: .network_length)
    }

    public var displayString: String {
        if let rawValue, !rawValue.isEmpty { return rawValue }
        guard let rawAddress = address?.addr else { return "" }
        let value = UInt32(truncatingIfNeeded: rawAddress)
        let octets = [
            (value >> 24) & 0xff,
            (value >> 16) & 0xff,
            (value >> 8) & 0xff,
            value & 0xff,
        ]
        let ip = octets.map(String.init).joined(separator: ".")
        if let network_length { return "\(ip)/\(network_length)" }
        return ip
    }
}

public struct URLValue: Codable, Equatable, Sendable {
    public var url: String?
}

public struct StunInfo: Codable, Equatable, Sendable {
    public var udp_nat_type: Int?
    public var tcp_nat_type: Int?
    public var last_update_time: Int64?

    enum CodingKeys: String, CodingKey {
        case udp_nat_type, tcp_nat_type, last_update_time
    }

    public init(udp_nat_type: Int? = nil, tcp_nat_type: Int? = nil, last_update_time: Int64? = nil) {
        self.udp_nat_type = udp_nat_type
        self.tcp_nat_type = tcp_nat_type
        self.last_update_time = last_update_time
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        udp_nat_type = container.decodeFlexibleNatType(forKeys: "udp_nat_type", "udpNatType")
        tcp_nat_type = container.decodeFlexibleNatType(forKeys: "tcp_nat_type", "tcpNatType")
        last_update_time = container.decodeFlexibleInt64(forKeys: "last_update_time", "lastUpdateTime")
    }
}

public struct Route: Codable, Equatable, Sendable {
    public var peer_id: Int?
    public var ipv4_addr: IPv4InetValue?
    public var next_hop_peer_id: Int?
    public var cost: Int?
    public var proxy_cidrs: [String]?
    public var hostname: String?
    public var stun_info: StunInfo?
    public var inst_id: String?
    public var version: String?
    public var feature_flag: PeerFeatureFlag?

    enum CodingKeys: String, CodingKey {
        case peer_id, ipv4_addr, next_hop_peer_id, cost, proxy_cidrs, hostname, stun_info, inst_id, version, feature_flag
    }

    public init(
        peer_id: Int? = nil,
        ipv4_addr: IPv4InetValue? = nil,
        next_hop_peer_id: Int? = nil,
        cost: Int? = nil,
        proxy_cidrs: [String]? = nil,
        hostname: String? = nil,
        stun_info: StunInfo? = nil,
        inst_id: String? = nil,
        version: String? = nil,
        feature_flag: PeerFeatureFlag? = nil
    ) {
        self.peer_id = peer_id
        self.ipv4_addr = ipv4_addr
        self.next_hop_peer_id = next_hop_peer_id
        self.cost = cost
        self.proxy_cidrs = proxy_cidrs
        self.hostname = hostname
        self.stun_info = stun_info
        self.inst_id = inst_id
        self.version = version
        self.feature_flag = feature_flag
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        peer_id = container.decodeFlexibleInt(forKeys: "peer_id", "peerId")
        ipv4_addr = try container.decodeIfPresent(IPv4InetValue.self, forKeys: "ipv4_addr", "ipv4Addr")
        next_hop_peer_id = container.decodeFlexibleInt(forKeys: "next_hop_peer_id", "nextHopPeerId")
        cost = container.decodeFlexibleInt(forKeys: "cost")
        proxy_cidrs = try container.decodeIfPresent([String].self, forKeys: "proxy_cidrs", "proxyCidrs")
        hostname = try container.decodeStringIfPresent("hostname")
        stun_info = try container.decodeIfPresent(StunInfo.self, forKeys: "stun_info", "stunInfo")
        inst_id = try container.decodeStringIfPresent("inst_id", "instId")
        version = try container.decodeStringIfPresent("version")
        feature_flag = try container.decodeIfPresent(PeerFeatureFlag.self, forKeys: "feature_flag", "featureFlag")
    }
}

public struct PeerInfo: Codable, Equatable, Sendable {
    public var peer_id: Int?
    public var conns: [PeerConnInfo]?
    public var default_conn_id: String?

    enum CodingKeys: String, CodingKey {
        case peer_id, conns, default_conn_id
    }

    public init(peer_id: Int? = nil, conns: [PeerConnInfo]? = nil, default_conn_id: String? = nil) {
        self.peer_id = peer_id
        self.conns = conns
        self.default_conn_id = default_conn_id
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        peer_id = container.decodeFlexibleInt(forKeys: "peer_id", "peerId")
        conns = try container.decodeLossyArray(PeerConnInfo.self, forKeys: "conns")
        default_conn_id = container.decodeFlexibleString(forKeys: "default_conn_id", "defaultConnId")
    }
}

public struct PeerConnInfo: Codable, Equatable, Sendable {
    public var conn_id: String?
    public var my_peer_id: Int?
    public var is_client: Bool?
    public var peer_id: Int?
    public var features: [String]?
    public var tunnel: TunnelInfo?
    public var loss_rate: Double?
    public var stats: PeerConnStats?

    enum CodingKeys: String, CodingKey {
        case conn_id, my_peer_id, is_client, peer_id, features, tunnel, loss_rate, stats
    }

    public init(
        conn_id: String? = nil,
        my_peer_id: Int? = nil,
        is_client: Bool? = nil,
        peer_id: Int? = nil,
        features: [String]? = nil,
        tunnel: TunnelInfo? = nil,
        loss_rate: Double? = nil,
        stats: PeerConnStats? = nil
    ) {
        self.conn_id = conn_id
        self.my_peer_id = my_peer_id
        self.is_client = is_client
        self.peer_id = peer_id
        self.features = features
        self.tunnel = tunnel
        self.loss_rate = loss_rate
        self.stats = stats
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        conn_id = try container.decodeStringIfPresent("conn_id", "connId")
        my_peer_id = container.decodeFlexibleInt(forKeys: "my_peer_id", "myPeerId")
        is_client = try container.decodeBoolIfPresent("is_client", "isClient")
        peer_id = container.decodeFlexibleInt(forKeys: "peer_id", "peerId")
        features = try container.decodeIfPresent([String].self, forKeys: "features")
        tunnel = try container.decodeIfPresent(TunnelInfo.self, forKeys: "tunnel")
        loss_rate = container.decodeFlexibleDouble(forKeys: "loss_rate", "lossRate")
        stats = try container.decodeIfPresent(PeerConnStats.self, forKeys: "stats")
    }
}

public struct TunnelInfo: Codable, Equatable, Sendable {
    public var tunnel_type: String?
    public var local_addr: URLValue?
    public var remote_addr: URLValue?
}

public struct PeerConnStats: Codable, Equatable, Sendable {
    public var rx_bytes: Int?
    public var tx_bytes: Int?
    public var rx_packets: Int?
    public var tx_packets: Int?
    public var latency_us: Int?

    enum CodingKeys: String, CodingKey {
        case rx_bytes, tx_bytes, rx_packets, tx_packets, latency_us
    }

    public init(rx_bytes: Int? = nil, tx_bytes: Int? = nil, rx_packets: Int? = nil, tx_packets: Int? = nil, latency_us: Int? = nil) {
        self.rx_bytes = rx_bytes
        self.tx_bytes = tx_bytes
        self.rx_packets = rx_packets
        self.tx_packets = tx_packets
        self.latency_us = latency_us
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rx_bytes = container.decodeFlexibleInt(forKey: .rx_bytes)
        tx_bytes = container.decodeFlexibleInt(forKey: .tx_bytes)
        rx_packets = container.decodeFlexibleInt(forKey: .rx_packets)
        tx_packets = container.decodeFlexibleInt(forKey: .tx_packets)
        latency_us = container.decodeFlexibleInt(forKey: .latency_us)
    }
}

public struct PeerRoutePair: Codable, Equatable, Sendable {
    public var route: Route?
    public var peer: PeerInfo?
}

public struct NetworkMemberStatus: Identifiable, Equatable, Sendable {
    public var id: String
    public var isLocal: Bool
    public var peerID: String
    public var instanceID: String?
    public var virtualIPv4: String
    public var hostname: String
    public var version: String
    public var routeCost: String
    public var tunnelProto: String
    public var latency: String
    public var uploadTotal: String
    public var downloadTotal: String
    public var lossRate: String
    public var natType: String
    public var isPublicServer: Bool
    public var txBytes: Int64
    public var rxBytes: Int64
}

public extension NetworkMemberStatus {
    var copyableIPv4Address: String? {
        let value = virtualIPv4.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != "-" else { return nil }

        let address = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? value
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAddress.isEmpty, trimmedAddress != "-" else { return nil }
        return trimmedAddress
    }
}

public struct TrafficSample: Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var timestamp: Date
    public var txBytesPerSecond: Double
    public var rxBytesPerSecond: Double

    public init(timestamp: Date = Date(), txBytesPerSecond: Double, rxBytesPerSecond: Double) {
        self.timestamp = timestamp
        self.txBytesPerSecond = txBytesPerSecond
        self.rxBytesPerSecond = rxBytesPerSecond
    }
}

public extension NetworkInstanceRunningInfo {
    var isFullyConnected: Bool {
        isFullyConnected(expectRemotePeers: false)
    }

    func isFullyConnected(expectRemotePeers: Bool) -> Bool {
        guard running != false else { return false }
        guard error_msg?.nilIfEmpty == nil else { return false }
        guard my_node_info != nil else { return false }

        let remotePairs = (peer_route_pairs ?? []).filter { !$0.representsLocalRoute }
        if !remotePairs.isEmpty {
            return remotePairs.allSatisfy(\.hasUsableRoute)
        }

        let remoteRoutes = (routes ?? []).filter { !$0.representsLocalRoute }
        if !remoteRoutes.isEmpty {
            return remoteRoutes.allSatisfy(\.hasUsableMachineAddress)
        }

        let remotePeers = peers ?? []
        if !remotePeers.isEmpty {
            return remotePeers.allSatisfy(\.hasActiveConnection)
        }

        return !expectRemotePeers
    }

    var memberStatuses: [NetworkMemberStatus] {
        var output: [NetworkMemberStatus] = []

        if let myNode = my_node_info {
            let peerID = myNode.peer_id.map(String.init) ?? "local"
            output.append(NetworkMemberStatus(
                id: "local-\(peerID)",
                isLocal: true,
                peerID: peerID,
                instanceID: nil,
                virtualIPv4: myNode.displayIPv4,
                hostname: myNode.hostname?.nilIfEmpty ?? "Local Node",
                version: myNode.version?.nilIfEmpty ?? "unknown",
                routeCost: "Local",
                tunnelProto: "-",
                latency: "-",
                uploadTotal: "-",
                downloadTotal: "-",
                lossRate: "-",
                natType: myNode.stun_info?.udpNATTypeName ?? "-",
                isPublicServer: myNode.feature_flag?.is_public_server == true,
                txBytes: 0,
                rxBytes: 0
            ))
        }

        for pair in peer_route_pairs ?? [] {
            output.append(NetworkMemberStatus(peerRoutePair: pair))
        }

        return output
    }

    var trafficTotals: (txBytes: Int64, rxBytes: Int64) {
        let sourcePeers: [PeerInfo]
        if let peer_route_pairs, !peer_route_pairs.isEmpty {
            sourcePeers = peer_route_pairs.compactMap(\.peer)
        } else {
            sourcePeers = peers ?? []
        }

        return sourcePeers.reduce((txBytes: 0, rxBytes: 0)) { partial, peer in
            let totals = peer.trafficTotals
            return (partial.txBytes + totals.txBytes, partial.rxBytes + totals.rxBytes)
        }
    }
}

public extension PeerRoutePair {
    var representsLocalRoute: Bool {
        route?.representsLocalRoute == true
    }

    var hasUsableRoute: Bool {
        route?.hasUsableMachineAddress == true || hasActiveConnection
    }

    var hasActiveConnection: Bool {
        peer?.hasActiveConnection == true
    }
}

public extension Route {
    var representsLocalRoute: Bool {
        cost == 0
    }

    var hasUsableMachineAddress: Bool {
        ipv4_addr?.displayString.nilIfEmpty != nil
    }
}

public extension PeerInfo {
    var hasActiveConnection: Bool {
        conns?.isEmpty == false
    }
}

public extension NetworkMemberStatus {
    init(peerRoutePair pair: PeerRoutePair) {
        let peer = pair.peer
        let route = pair.route
        let totals = peer?.trafficTotals ?? (txBytes: 0, rxBytes: 0)
        let peerID = route?.peer_id ?? peer?.peer_id

        self.init(
            id: "peer-\(peerID.map(String.init) ?? "unknown")",
            isLocal: false,
            peerID: peerID.map(String.init) ?? "-",
            instanceID: route?.inst_id?.nilIfEmpty,
            virtualIPv4: route?.ipv4_addr?.displayString.nilIfEmpty ?? "-",
            hostname: route?.hostname?.nilIfEmpty ?? "-",
            version: route?.version?.nilIfEmpty ?? "unknown",
            routeCost: route?.routeCostLabel ?? "-",
            tunnelProto: peer?.tunnelProto.nilIfEmpty ?? "-",
            latency: peer?.latencyLabel ?? "-",
            uploadTotal: totals.txBytes > 0 ? ByteFormatter.format(totals.txBytes) : "-",
            downloadTotal: totals.rxBytes > 0 ? ByteFormatter.format(totals.rxBytes) : "-",
            lossRate: peer?.lossRateLabel ?? "-",
            natType: route?.stun_info?.udpNATTypeName ?? "-",
            isPublicServer: route?.isPublicServer == true,
            txBytes: totals.txBytes,
            rxBytes: totals.rxBytes
        )
    }
}

public extension Route {
    var isPublicServer: Bool {
        feature_flag?.is_public_server == true || hostname?.hasPrefix("PublicServer_") == true
    }
}

public extension NodeInfo {
    var displayIPv4: String {
        if let ipv4 = virtual_ipv4?.displayString.nilIfEmpty { return ipv4 }
        return ipv4_addr?.nilIfEmpty ?? "-"
    }
}

public extension PeerInfo {
    var trafficTotals: (txBytes: Int64, rxBytes: Int64) {
        let validStats: [PeerConnStats] = (conns ?? []).compactMap { $0.stats }
        var tx: Int64 = 0
        var rx: Int64 = 0
        for stats in validStats {
            tx += Int64(stats.tx_bytes ?? 0)
            rx += Int64(stats.rx_bytes ?? 0)
        }
        return (tx, rx)
    }

    var latencyLabel: String {
        let latencies = (conns ?? []).compactMap { $0.stats?.latency_us }
        guard !latencies.isEmpty else { return "" }
        let average = Double(latencies.reduce(0, +)) / Double(latencies.count) / 1000.0
        return "\(Int(average.rounded(.up))) ms"
    }

    var lossRateLabel: String {
        guard let conns else { return "" }
        let total = conns.reduce(0.0) { partial, conn in
            partial + (conn.loss_rate ?? 0)
        }
        return "\(Int((total * 100).rounded()))%"
    }

    var tunnelProto: String {
        let values = (conns ?? []).compactMap { conn -> String? in
            guard let type = conn.tunnel?.tunnel_type, !type.isEmpty else { return nil }
            guard let url = conn.tunnel?.local_addr?.url else { return type }
            return url.contains("[") ? "\(type)6" : type
        }
        return Array(Set(values)).sorted().joined(separator: ", ")
    }
}

public extension Route {
    var routeCostLabel: String {
        guard let cost else { return "Local" }
        if cost == 0 { return "Local" }
        if cost == 1 { return "P2P" }
        return "Relay (\(cost))"
    }
}

public extension StunInfo {
    var udpNATTypeName: String {
        switch udp_nat_type {
        case 0: "Unknown"
        case 1: "Open Internet"
        case 2: "No PAT"
        case 3: "Full Cone"
        case 4: "Restricted"
        case 5: "Port Restricted"
        case 6: "Symmetric"
        case 7: "Symmetric UDP Firewall"
        case 8: "Symmetric Easy Inc"
        case 9: "Symmetric Easy Dec"
        default: ""
        }
    }
}

public enum ByteFormatter {
    public static func format(_ bytes: Int64, suffix: String = "") -> String {
        let units = ["B", "KiB", "MiB", "GiB", "TiB"]
        var value = Double(bytes)
        var unitIndex = 0
        while abs(value) >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        if unitIndex == 0 {
            return "\(Int(value)) \(units[unitIndex])\(suffix)"
        }
        return "\(String(format: "%.1f", value)) \(units[unitIndex])\(suffix)"
    }

    public static func formatRate(_ bytesPerSecond: Double) -> String {
        format(Int64(max(0, bytesPerSecond).rounded()), suffix: "/s")
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension KeyedDecodingContainer {
    func decodeFlexibleInt(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return Int(clamping: value) }
        if let value = try? decodeIfPresent(UInt64.self, forKey: key) { return Int(clamping: value) }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return Int(value) }
        if let value = try? decodeIfPresent(String.self, forKey: key) { return Int(value) }
        return nil
    }

    func decodeFlexibleInt64(forKey key: Key) -> Int64? {
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return Int64(value) }
        if let value = try? decodeIfPresent(UInt64.self, forKey: key) { return Int64(clamping: value) }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return Int64(value) }
        if let value = try? decodeIfPresent(String.self, forKey: key) { return Int64(value) }
        return nil
    }

    func decodeFlexibleDouble(forKey key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return Double(value) }
        if let value = try? decodeIfPresent(String.self, forKey: key) { return Double(value) }
        return nil
    }

    func decodeFlexibleString(forKey key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return String(value) }
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return String(value) }
        if let value = try? decodeIfPresent(UInt64.self, forKey: key) { return String(value) }
        return nil
    }

    func decodeLossyArray<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> [T]? {
        guard contains(key) else { return nil }
        var container = try nestedUnkeyedContainer(forKey: key)
        var output: [T] = []
        while !container.isAtEnd {
            if let value = try? container.decode(T.self) {
                output.append(value)
            } else {
                _ = try? container.decode(DiscardedDecodable.self)
            }
        }
        return output
    }
}

private extension KeyedDecodingContainer where Key == AnyCodingKey {
    func key(_ name: String) -> AnyCodingKey { AnyCodingKey(stringValue: name) }

    func decodeIfPresent<T: Decodable>(_ type: T.Type, forKeys keys: String...) throws -> T? {
        for keyName in keys {
            if let value = try decodeIfPresent(type, forKey: key(keyName)) { return value }
        }
        return nil
    }

    func decodeStringIfPresent(_ keys: String...) throws -> String? {
        for keyName in keys {
            if let value = try decodeIfPresent(String.self, forKey: key(keyName)) { return value }
        }
        return nil
    }

    func decodeBoolIfPresent(_ keys: String...) throws -> Bool? {
        for keyName in keys {
            if let value = try decodeIfPresent(Bool.self, forKey: key(keyName)) { return value }
        }
        return nil
    }

    func decodeFlexibleInt(forKeys keys: String...) -> Int? {
        for keyName in keys {
            if let value = decodeFlexibleInt(forKey: key(keyName)) { return value }
        }
        return nil
    }

    func decodeFlexibleInt64(forKeys keys: String...) -> Int64? {
        for keyName in keys {
            if let value = decodeFlexibleInt64(forKey: key(keyName)) { return value }
        }
        return nil
    }

    func decodeFlexibleDouble(forKeys keys: String...) -> Double? {
        for keyName in keys {
            if let value = decodeFlexibleDouble(forKey: key(keyName)) { return value }
        }
        return nil
    }

    func decodeFlexibleString(forKeys keys: String...) -> String? {
        for keyName in keys {
            if let value = decodeFlexibleString(forKey: key(keyName)) { return value }
        }
        return nil
    }

    func decodeFlexibleNatType(forKeys keys: String...) -> Int? {
        for keyName in keys {
            if let value = decodeFlexibleInt(forKey: key(keyName)) { return value }
            if let raw = try? decodeIfPresent(String.self, forKey: key(keyName)),
               let value = Self.natTypeValue(raw) {
                return value
            }
        }
        return nil
    }

    private static func natTypeValue(_ raw: String) -> Int? {
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
            .lowercased()

        switch normalized {
        case "0", "unknown": return 0
        case "1", "openinternet": return 1
        case "2", "nopat": return 2
        case "3", "fullcone": return 3
        case "4", "restricted": return 4
        case "5", "portrestricted": return 5
        case "6", "symmetric": return 6
        case "7", "symudpfirewall", "symmetricudpfirewall": return 7
        case "8", "symmetriceasyinc": return 8
        case "9", "symmetriceasydec": return 9
        default: return nil
        }
    }

    func decodeLossyArray<T: Decodable>(_ type: T.Type, forKeys keys: String...) throws -> [T]? {
        for keyName in keys {
            let k = key(keyName)
            if !contains(k) { continue }
            return try decodeLossyArray(type, forKey: k)
        }
        return nil
    }
}

private struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

private struct DiscardedDecodable: Decodable {}
