import Foundation

struct PatchConfigRequestPayload: Encodable {
    var patch: InstanceConfigPatchPayload
    var instance: InstanceIdentifierPayload
}

struct ValidateNetworkConfigRequestPayload: Encodable {
    var config: NetworkConfig
}

struct RunNetworkInstanceRequestPayload: Encodable {
    var instanceID: RPCUUID
    var config: NetworkConfig
    var overwrite: Bool
    var source: ConfigSourcePayload

    enum CodingKeys: String, CodingKey {
        case instanceID = "inst_id"
        case config
        case overwrite
        case source
    }
}

enum ConfigSourcePayload: Int, Encodable {
    case unspecified = 0
}

struct InstanceConfigPatchPayload: Encodable {
    var hostname: String?
    var ipv4: IPv4InetPayload?
    var portForwards: [PortForwardPatchPayload]
    var proxyNetworks: [ProxyNetworkPatchPayload]
    var routes: [RoutePatchPayload]
    var exitNodes: [ExitNodePatchPayload]
    var mappedListeners: [URLPatchPayload]
    var connectors: [URLPatchPayload]
    var ipv6PublicAddrAuto: Bool?

    static let empty = InstanceConfigPatchPayload()

    var hasChanges: Bool {
        hostname != nil
            || ipv4 != nil
            || !portForwards.isEmpty
            || !proxyNetworks.isEmpty
            || !routes.isEmpty
            || !exitNodes.isEmpty
            || !mappedListeners.isEmpty
            || !connectors.isEmpty
            || ipv6PublicAddrAuto != nil
    }

    init(
        hostname: String? = nil,
        ipv4: IPv4InetPayload? = nil,
        portForwards: [PortForwardPatchPayload] = [],
        proxyNetworks: [ProxyNetworkPatchPayload] = [],
        routes: [RoutePatchPayload] = [],
        exitNodes: [ExitNodePatchPayload] = [],
        mappedListeners: [URLPatchPayload] = [],
        connectors: [URLPatchPayload] = [],
        ipv6PublicAddrAuto: Bool? = nil
    ) {
        self.hostname = hostname
        self.ipv4 = ipv4
        self.portForwards = portForwards
        self.proxyNetworks = proxyNetworks
        self.routes = routes
        self.exitNodes = exitNodes
        self.mappedListeners = mappedListeners
        self.connectors = connectors
        self.ipv6PublicAddrAuto = ipv6PublicAddrAuto
    }

    static func hostname(_ hostname: String) -> Self {
        Self(hostname: hostname)
    }

    enum CodingKeys: String, CodingKey {
        case hostname
        case ipv4
        case portForwards = "port_forwards"
        case proxyNetworks = "proxy_networks"
        case routes
        case exitNodes = "exit_nodes"
        case mappedListeners = "mapped_listeners"
        case connectors
        case ipv6PublicAddrAuto = "ipv6_public_addr_auto"
    }
}

enum ConfigPatchActionPayload: Int, Encodable {
    case add = 0
    case remove = 1
    case clear = 2
}

struct PortForwardPatchPayload: Encodable {
    var action: ConfigPatchActionPayload
    var cfg: PortForwardConfigPayload?

    static func add(_ cfg: PortForwardConfigPayload) -> Self {
        Self(action: .add, cfg: cfg)
    }

    static func remove(_ cfg: PortForwardConfigPayload) -> Self {
        Self(action: .remove, cfg: cfg)
    }

    static func clear() -> Self {
        Self(action: .clear, cfg: nil)
    }
}

struct ProxyNetworkPatchPayload: Encodable {
    var action: ConfigPatchActionPayload
    var cidr: IPv4InetPayload?
    var mappedCidr: IPv4InetPayload?

    enum CodingKeys: String, CodingKey {
        case action
        case cidr
        case mappedCidr = "mapped_cidr"
    }
}

struct RoutePatchPayload: Encodable {
    var action: ConfigPatchActionPayload
    var cidr: IPv4InetPayload?

    static func add(_ cidr: IPv4InetPayload) -> Self {
        Self(action: .add, cidr: cidr)
    }

    static func clear() -> Self {
        Self(action: .clear, cidr: nil)
    }
}

struct ExitNodePatchPayload: Encodable {
    var action: ConfigPatchActionPayload
    var node: IPAddressPayload?

    static func add(_ node: IPAddressPayload) -> Self {
        Self(action: .add, node: node)
    }

    static func clear() -> Self {
        Self(action: .clear, node: nil)
    }
}

struct URLPatchPayload: Encodable {
    var action: ConfigPatchActionPayload
    var url: URLValuePayload?

    static func add(_ url: String) -> Self {
        Self(action: .add, url: URLValuePayload(url: url))
    }

    static func clear() -> Self {
        Self(action: .clear, url: nil)
    }
}

struct PortForwardConfigPayload: Encodable {
    var bindAddr: SocketAddressPayload
    var dstAddr: SocketAddressPayload
    var socketType: Int

    enum CodingKeys: String, CodingKey {
        case bindAddr = "bind_addr"
        case dstAddr = "dst_addr"
        case socketType = "socket_type"
    }
}

struct SocketAddressPayload: Encodable {
    var ip: IPAddressOneOfPayload
    var port: Int

    init(ipv4: IPv4AddressPayload, port: Int) {
        self.ip = .ipv4(ipv4)
        self.port = port
    }
}

struct IPAddressPayload: Encodable {
    var ip: IPAddressOneOfPayload

    init(ipv4: IPv4AddressPayload) {
        self.ip = .ipv4(ipv4)
    }
}

enum IPAddressOneOfPayload: Encodable {
    case ipv4(IPv4AddressPayload)

    enum CodingKeys: String, CodingKey {
        case ipv4 = "Ipv4"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .ipv4(value):
            try container.encode(value, forKey: .ipv4)
        }
    }
}

struct IPv4InetPayload: Encodable {
    var address: IPv4AddressPayload
    var networkLength: Int

    enum CodingKeys: String, CodingKey {
        case address
        case networkLength = "network_length"
    }
}

struct IPv4AddressPayload: Encodable {
    var addr: Int
}

struct URLValuePayload: Encodable {
    var url: String
}

struct InstanceRequestPayload: Encodable {
    var instance: InstanceIdentifierPayload
}

struct InstanceIdentifierPayload: Encodable {
    var selector: InstanceIdentifierSelectorPayload

    init(id: RPCUUID) {
        self.selector = InstanceIdentifierSelectorPayload(id: id)
    }
}

struct InstanceIdentifierSelectorPayload: Encodable {
    var id: RPCUUID

    enum CodingKeys: String, CodingKey {
        case id = "Id"
    }
}

struct RPCUUID: Encodable {
    var part1: UInt32
    var part2: UInt32
    var part3: UInt32
    var part4: UInt32

    init(uuid: UUID) {
        let bytes = uuid.uuid
        self.part1 = Self.part(bytes.0, bytes.1, bytes.2, bytes.3)
        self.part2 = Self.part(bytes.4, bytes.5, bytes.6, bytes.7)
        self.part3 = Self.part(bytes.8, bytes.9, bytes.10, bytes.11)
        self.part4 = Self.part(bytes.12, bytes.13, bytes.14, bytes.15)
    }

    private static func part(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8, _ b3: UInt8) -> UInt32 {
        UInt32(b0) << 24 | UInt32(b1) << 16 | UInt32(b2) << 8 | UInt32(b3)
    }
}
