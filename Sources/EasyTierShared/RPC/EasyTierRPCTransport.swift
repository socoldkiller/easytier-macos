import Foundation

public struct EasyTierRPCRequest: Equatable, Sendable {
    public var service: String
    public var method: String
    public var domain: String?
    public var payload: String

    public init(service: String, method: String, domain: String? = nil, payload: String) {
        self.service = service
        self.method = method
        self.domain = domain
        self.payload = payload
    }
}

public protocol EasyTierRPCTransport: Sendable {
    func call(_ request: EasyTierRPCRequest) async throws -> String
}

public struct LocalFFIRPCTransport: EasyTierRPCTransport {
    public let rpcURL: URL
    public let clientID: String

    private let client: PrivilegedEasyTierClient

    public init(rpcURL: URL, clientID: String? = nil, client: PrivilegedEasyTierClient = PrivilegedEasyTierClient()) {
        self.rpcURL = rpcURL
        self.clientID = clientID ?? Self.defaultClientID(for: rpcURL)
        self.client = client
    }

    public func call(_ request: EasyTierRPCRequest) async throws -> String {
        try await client.connectRPCClient(clientID: clientID, url: rpcURL)
        return try await client.callJSONRPC(
            clientID: clientID,
            service: request.service,
            method: request.method,
            domain: request.domain,
            payload: request.payload
        )
    }

    public func disconnect() async throws {
        try await client.disconnectRPCClient(clientID: clientID)
    }

    private static func defaultClientID(for rpcURL: URL) -> String {
        let hex = rpcURL.absoluteString.utf8.map { String(format: "%02x", Int($0)) }.joined()
        return "local-ffi-rpc-\(hex)"
    }
}

public struct EasyTierRemoteRPCClient: Sendable {
    private let transport: any EasyTierRPCTransport

    public init(transport: any EasyTierRPCTransport) {
        self.transport = transport
    }

    public init(rpcURL: URL, privilegedClient: PrivilegedEasyTierClient = PrivilegedEasyTierClient()) {
        self.init(transport: LocalFFIRPCTransport(rpcURL: rpcURL, client: privilegedClient))
    }

    public func call(_ request: EasyTierRPCRequest) async throws -> String {
        try await transport.call(request)
    }

    public func getConfig(instanceID: String) async throws -> String {
        try await call(EasyTierRPCRequest(
            service: Self.configService,
            method: "get_config",
            payload: try Self.instancePayload(instanceID: instanceID)
        ))
    }

    public func getConfigParsed(instanceID: String) async throws -> NetworkConfig {
        let response = try await getConfig(instanceID: instanceID)
        return try Self.parseGetConfigResponse(response)
    }

    public func listPeers(instanceID: String) async throws -> String {
        try await call(EasyTierRPCRequest(
            service: Self.peerManageService,
            method: "list_peer",
            payload: try Self.instancePayload(instanceID: instanceID)
        ))
    }

    public func listPortForwards(instanceID: String) async throws -> String {
        try await call(EasyTierRPCRequest(
            service: Self.portForwardService,
            method: "list_port_forward",
            payload: try Self.instancePayload(instanceID: instanceID)
        ))
    }

    @discardableResult
    public func patchHostname(instanceID: String, hostname: String) async throws -> String {
        try await patchConfig(instanceID: instanceID, runtimePatch: Self.hostnamePatch(hostname))
    }

    @discardableResult
    public func patchPortForwards(instanceID: String, portForwards: [PortForwardConfig]) async throws -> String {
        let runtimePatch = try Self.portForwardsPatch(portForwards)
        return try await patchConfig(instanceID: instanceID, runtimePatch: runtimePatch)
    }

    @discardableResult
    public func patchPortForwardAdd(instanceID: String, portForward: PortForwardConfig) async throws -> String {
        let runtimePatch = try Self.portForwardAddPatch(portForward)
        return try await patchConfig(instanceID: instanceID, runtimePatch: runtimePatch)
    }

    @discardableResult
    public func patchPortForwardRemove(instanceID: String, portForward: PortForwardConfig) async throws -> String {
        let runtimePatch = try Self.portForwardRemovePatch(portForward)
        return try await patchConfig(instanceID: instanceID, runtimePatch: runtimePatch)
    }

    public func listPortForwardsParsed(instanceID: String) async throws -> [PortForwardConfig] {
        let response = try await listPortForwards(instanceID: instanceID)
        return try Self.parseListPortForwardsResponse(response)
    }

    @discardableResult
    public func patchConfig(instanceID: String, runtimePatch: [String: Any]) async throws -> String {
        let runtimePayload = try Self.patchConfigPayload(instanceID: instanceID, patch: runtimePatch)
        return try await call(EasyTierRPCRequest(
            service: Self.configService,
            method: "patch_config",
            payload: runtimePayload
        ))
    }

    @discardableResult
    public func applyConfigPatch(instanceID: String, config: NetworkConfig, original: NetworkConfig) async throws -> String {
        let patch = try Self.configPatch(config: config, original: original)
        guard !patch.isEmpty else { return "" }
        return try await patchConfig(instanceID: instanceID, runtimePatch: patch)
    }

    public static func getConfig(rpcURL: URL, instanceID: String, privilegedClient: PrivilegedEasyTierClient = PrivilegedEasyTierClient()) async throws -> String {
        try await EasyTierRemoteRPCClient(rpcURL: rpcURL, privilegedClient: privilegedClient).getConfig(instanceID: instanceID)
    }

    public static func getConfigParsed(rpcURL: URL, instanceID: String, privilegedClient: PrivilegedEasyTierClient = PrivilegedEasyTierClient()) async throws -> NetworkConfig {
        try await EasyTierRemoteRPCClient(rpcURL: rpcURL, privilegedClient: privilegedClient).getConfigParsed(instanceID: instanceID)
    }

    public static func listPeers(rpcURL: URL, instanceID: String, privilegedClient: PrivilegedEasyTierClient = PrivilegedEasyTierClient()) async throws -> String {
        try await EasyTierRemoteRPCClient(rpcURL: rpcURL, privilegedClient: privilegedClient).listPeers(instanceID: instanceID)
    }

    public static func listPortForwards(rpcURL: URL, instanceID: String, privilegedClient: PrivilegedEasyTierClient = PrivilegedEasyTierClient()) async throws -> String {
        try await EasyTierRemoteRPCClient(rpcURL: rpcURL, privilegedClient: privilegedClient).listPortForwards(instanceID: instanceID)
    }

    @discardableResult
    public static func patchHostname(rpcURL: URL, instanceID: String, hostname: String, privilegedClient: PrivilegedEasyTierClient = PrivilegedEasyTierClient()) async throws -> String {
        try await EasyTierRemoteRPCClient(rpcURL: rpcURL, privilegedClient: privilegedClient).patchHostname(instanceID: instanceID, hostname: hostname)
    }

    @discardableResult
    public static func patchPortForwards(rpcURL: URL, instanceID: String, portForwards: [PortForwardConfig], privilegedClient: PrivilegedEasyTierClient = PrivilegedEasyTierClient()) async throws -> String {
        try await EasyTierRemoteRPCClient(rpcURL: rpcURL, privilegedClient: privilegedClient).patchPortForwards(instanceID: instanceID, portForwards: portForwards)
    }

    @discardableResult
    public static func patchPortForwardAdd(rpcURL: URL, instanceID: String, portForward: PortForwardConfig, privilegedClient: PrivilegedEasyTierClient = PrivilegedEasyTierClient()) async throws -> String {
        try await EasyTierRemoteRPCClient(rpcURL: rpcURL, privilegedClient: privilegedClient).patchPortForwardAdd(instanceID: instanceID, portForward: portForward)
    }

    @discardableResult
    public static func patchPortForwardRemove(rpcURL: URL, instanceID: String, portForward: PortForwardConfig, privilegedClient: PrivilegedEasyTierClient = PrivilegedEasyTierClient()) async throws -> String {
        try await EasyTierRemoteRPCClient(rpcURL: rpcURL, privilegedClient: privilegedClient).patchPortForwardRemove(instanceID: instanceID, portForward: portForward)
    }

    public static func listPortForwardsParsed(rpcURL: URL, instanceID: String, privilegedClient: PrivilegedEasyTierClient = PrivilegedEasyTierClient()) async throws -> [PortForwardConfig] {
        try await EasyTierRemoteRPCClient(rpcURL: rpcURL, privilegedClient: privilegedClient).listPortForwardsParsed(instanceID: instanceID)
    }

    @discardableResult
    public static func applyConfigPatch(rpcURL: URL, instanceID: String, config: NetworkConfig, original: NetworkConfig, privilegedClient: PrivilegedEasyTierClient = PrivilegedEasyTierClient()) async throws -> String {
        try await EasyTierRemoteRPCClient(rpcURL: rpcURL, privilegedClient: privilegedClient).applyConfigPatch(instanceID: instanceID, config: config, original: original)
    }
}

extension EasyTierRemoteRPCClient {
    static let configService = "api.config.ConfigRpcService"
    static let peerManageService = "api.instance.PeerManageRpcService"
    static let portForwardService = "api.instance.PortForwardManageRpcService"
    static let webClientService = "api.manage.WebClientService"

    static func instancePayload(instanceID: String) throws -> String {
        try encodePayload(InstanceRequestPayload(instance: instanceIdentifier(instanceID: instanceID)))
    }

    static func patchConfigPayload(instanceID: String, patch: [String: Any]) throws -> String {
        let payload: [String: Any] = [
            "patch": patch,
            "instance": try jsonObject(instanceIdentifier(instanceID: instanceID)),
        ]
        return try jsonString(payload)
    }

    static func runNetworkInstancePayload(instanceID: String, getConfigResponse: String, mutate: (inout [String: Any]) throws -> Void) throws -> String {
        guard let data = getConfigResponse.data(using: .utf8),
              let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var config = response["config"] as? [String: Any]
        else {
            throw EasyTierCoreError.invalidResponse("RPC get_config response did not include a config object")
        }

        try mutate(&config)
        return try runNetworkInstancePayload(instanceID: instanceID, config: config)
    }

    static func runNetworkInstancePayload(instanceID: String, config: [String: Any]) throws -> String {
        let payload: [String: Any] = [
            "inst_id": try rpcUUIDPayload(instanceID: instanceID),
            "config": config,
            "overwrite": true,
            "source": 1,
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let json = String(data: payloadData, encoding: .utf8) else {
            throw EasyTierCoreError.invalidResponse("failed to encode run_network_instance payload as UTF-8")
        }
        return json
    }

    private static func instanceIdentifier(instanceID: String) throws -> InstanceIdentifierPayload {
        guard let uuid = UUID(uuidString: instanceID) else {
            throw EasyTierRPCError.invalidInstanceID(instanceID)
        }
        return InstanceIdentifierPayload(id: RPCUUID(uuid: uuid))
    }

    private static func rpcUUIDPayload(instanceID: String) throws -> [String: Int] {
        guard let uuid = UUID(uuidString: instanceID) else {
            throw EasyTierRPCError.invalidInstanceID(instanceID)
        }
        let id = RPCUUID(uuid: uuid)
        return [
            "part1": Int(id.part1),
            "part2": Int(id.part2),
            "part3": Int(id.part3),
            "part4": Int(id.part4),
        ]
    }

    private static func encodePayload(_ payload: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        guard let json = String(data: data, encoding: .utf8) else {
            throw EasyTierCoreError.invalidResponse("failed to encode RPC payload as UTF-8")
        }
        return json
    }

    private static func jsonObject(_ value: some Encodable) throws -> Any {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }

    private static func jsonString(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw EasyTierCoreError.invalidResponse("failed to encode RPC payload as UTF-8")
        }
        return json
    }

    private static func hostnamePatch(_ hostname: String) -> [String: Any] {
        [
            "hostname": hostname,
            "port_forwards": [],
            "proxy_networks": [],
            "routes": [],
            "exit_nodes": [],
            "mapped_listeners": [],
            "connectors": [],
        ]
    }

    private static func portForwardsPatch(_ portForwards: [PortForwardConfig]) throws -> [String: Any] {
        var patches: [[String: Any]] = [["action": 2]]
        for portForward in portForwards {
            patches.append(["action": 0, "cfg": try portForwardPatchConfig(portForward)])
        }
        return basePatchFields().merging(["port_forwards": patches]) { $1 }
    }

    private static func portForwardAddPatch(_ portForward: PortForwardConfig) throws -> [String: Any] {
        return basePatchFields().merging(
            ["port_forwards": [["action": 0, "cfg": try portForwardPatchConfig(portForward)]]]
        ) { $1 }
    }

    private static func portForwardRemovePatch(_ portForward: PortForwardConfig) throws -> [String: Any] {
        return basePatchFields().merging(
            ["port_forwards": [["action": 1, "cfg": try portForwardPatchConfig(portForward)]]]
        ) { $1 }
    }

    private static func basePatchFields() -> [String: Any] {
        [
            "proxy_networks": [],
            "routes": [],
            "exit_nodes": [],
            "mapped_listeners": [],
            "connectors": [],
        ]
    }

    private static func portForwardPatchConfig(_ portForward: PortForwardConfig) throws -> [String: Any] {
        let socketType: Int
        switch portForward.proto.lowercased() {
        case "tcp": socketType = 0
        case "udp": socketType = 1
        default: throw EasyTierCoreError.invalidResponse("port forward protocol must be tcp or udp")
        }
        return [
            "bind_addr": try socketAddress(ip: portForward.bind_ip, port: portForward.bind_port),
            "dst_addr": try socketAddress(ip: portForward.dst_ip, port: portForward.dst_port),
            "socket_type": socketType,
        ]
    }

    public static func parseListPortForwardsResponse(_ response: String) throws -> [PortForwardConfig] {
        guard let data = response.data(using: .utf8) else {
            throw EasyTierCoreError.invalidResponse("port forward list response is not valid UTF-8")
        }
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw EasyTierCoreError.invalidResponse("port forward list response is not valid JSON: \(error)")
        }
        guard let object = json as? [String: Any] else {
            throw EasyTierCoreError.invalidResponse("port forward list response root is not a JSON object")
        }
        guard let cfgs = object["cfgs"] as? [[String: Any]] else {
            throw EasyTierCoreError.invalidResponse("port forward list response missing 'cfgs' array")
        }
        return try cfgs.map { try parsePortForwardConfigJson($0) }
    }

    private static func parsePortForwardConfigJson(_ cfg: [String: Any]) throws -> PortForwardConfig {
        guard let socketType = cfg["socket_type"] as? Int,
              let bindAddr = cfg["bind_addr"] as? [String: Any],
              let dstAddr = cfg["dst_addr"] as? [String: Any]
        else {
            throw EasyTierCoreError.invalidResponse("invalid port forward cfg in list response")
        }

        let proto = socketType == 1 ? "udp" : "tcp"
        let bind_ip = try parseIPv4Address(from: bindAddr)
        guard let bind_port = bindAddr["port"] as? Int else {
            throw EasyTierCoreError.invalidResponse("port forward bind_addr missing 'port'")
        }
        let dst_ip = try parseIPv4Address(from: dstAddr)
        guard let dst_port = dstAddr["port"] as? Int else {
            throw EasyTierCoreError.invalidResponse("port forward dst_addr missing 'port'")
        }

        return PortForwardConfig(bind_ip: bind_ip, bind_port: bind_port, dst_ip: dst_ip, dst_port: dst_port, proto: proto)
    }

    private static func parseIPv4Address(from socketAddr: [String: Any]) throws -> String {
        let ipObj = (socketAddr["ip"] as? [String: Any]) ?? socketAddr
        guard let ipv4 = ipObj["Ipv4"] as? [String: Any] ?? ipObj["ipv4"] as? [String: Any],
              let addr = ipv4["addr"] as? Int
        else {
            throw EasyTierCoreError.invalidResponse("invalid or missing ipv4 address in socket addr")
        }
        var value = UInt32(truncatingIfNeeded: addr)
        var octets = [UInt8](repeating: 0, count: 4)
        for i in (0...3).reversed() {
            octets[i] = UInt8(value & 0xff)
            value >>= 8
        }
        return octets.map(String.init).joined(separator: ".")
    }

    private static func socketAddress(ip: String, port: Int) throws -> [String: Any] {
        guard (1...65_535).contains(port) else {
            throw EasyTierCoreError.invalidResponse("port forward port is out of range")
        }
        return ["ip": ["Ipv4": ["addr": try ipv4Address(ip)]], "port": port]
    }

    private static func ipv4Address(_ value: String) throws -> Int {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else {
            throw EasyTierCoreError.invalidResponse("port forward address must be IPv4")
        }
        var result = 0
        for part in parts {
            guard let byte = UInt8(String(part)) else {
                throw EasyTierCoreError.invalidResponse("port forward address must be IPv4")
            }
            result = (result << 8) | Int(byte)
        }
        return result
    }

    // MARK: - get_config response parsing

    static func parseGetConfigResponse(_ response: String) throws -> NetworkConfig {
        guard let data = response.data(using: .utf8) else {
            throw EasyTierCoreError.invalidResponse("get_config response is not valid UTF-8")
        }
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw EasyTierCoreError.invalidResponse("get_config response is not valid JSON: \(error)")
        }
        guard let object = root as? [String: Any] else {
            throw EasyTierCoreError.invalidResponse("get_config response root is not a JSON object")
        }
        guard let configObj = object["config"] else {
            throw EasyTierCoreError.invalidResponse("get_config response did not include a config object")
        }
        let configData = try JSONSerialization.data(withJSONObject: normalizedGetConfigObject(configObj), options: [])
        do {
            return try JSONDecoder().decode(NetworkConfig.self, from: configData)
        } catch {
            throw EasyTierCoreError.invalidResponse("failed to decode remote config: \(error)")
        }
    }

    static func normalizedGetConfigObject(_ configObj: Any) -> Any {
        guard var config = configObj as? [String: Any] else {
            return configObj
        }

        for key in config.keys where config[key] is NSNull {
            if let value = remoteConfigNullDefault(for: key) {
                config[key] = value
            }
        }

        return config
    }

    static func remoteConfigNullDefault(for key: String) -> Any? {
        switch key {
        case "dhcp": true
        case "virtual_ipv4": ""
        case "network_length": 24
        case "network_name": "easytier"
        case "networking_method": NetworkingMethod.manual.rawValue
        case "public_server_url": ""
        case "peer_urls": []
        case "proxy_cidrs": []
        case "enable_vpn_portal": false
        case "vpn_portal_listen_port": 22_022
        case "vpn_portal_client_network_addr": ""
        case "vpn_portal_client_network_len": 24
        case "advanced_settings": false
        case "listener_urls": ListenerURLDefaults.addSuggestions
        case "latency_first": false
        case "dev_name": ""
        case "relay_network_whitelist": []
        case "enable_manual_routes": false
        case "routes": []
        case "exit_nodes": []
        case "socks5_port": 1_080
        case "mapped_listeners": []
        case "port_forwards": []
        default: nil
        }
    }

    // MARK: - patch_config delta builder

    static func configPatch(config: NetworkConfig, original: NetworkConfig) throws -> [String: Any] {
        var patch: [String: Any] = [:]

        if config.hostname != original.hostname {
            patch["hostname"] = config.hostname ?? ""
        }

        if config.virtual_ipv4 != original.virtual_ipv4 || config.network_length != original.network_length {
            if !config.virtual_ipv4.isEmpty {
                patch["ipv4"] = try ipv4InetPayload(ip: config.virtual_ipv4, networkLength: config.network_length)
            }
        }

        if config.ipv6_public_addr_auto != original.ipv6_public_addr_auto {
            patch["ipv6_public_addr_auto"] = config.ipv6_public_addr_auto ?? false
        }

        if config.port_forwards != original.port_forwards {
            patch["port_forwards"] = try portForwardsListPatch(config.port_forwards)
        }

        if config.routes != original.routes {
            patch["routes"] = try routeListPatch(config.routes)
        }

        if config.exit_nodes != original.exit_nodes {
            patch["exit_nodes"] = try exitNodeListPatch(config.exit_nodes)
        }

        if config.mapped_listeners != original.mapped_listeners {
            patch["mapped_listeners"] = try mappedListenerListPatch(config.mapped_listeners)
        }

        return patch
    }

    static func portForwardsListPatch(_ portForwards: [PortForwardConfig]) throws -> [[String: Any]] {
        var patches: [[String: Any]] = [["action": 2]]
        for portForward in portForwards {
            patches.append(["action": 0, "cfg": try portForwardPatchConfig(portForward)])
        }
        return patches
    }

    static func routeListPatch(_ routes: [String]) throws -> [[String: Any]] {
        var patches: [[String: Any]] = [["action": 2]]
        for route in routes {
            let trimmed = route.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let (ip, prefix) = try parseCIDR(trimmed)
            patches.append(["action": 0, "cidr": try ipv4InetPayload(ip: ip, networkLength: prefix)])
        }
        return patches
    }

    static func exitNodeListPatch(_ exitNodes: [String]) throws -> [[String: Any]] {
        var patches: [[String: Any]] = [["action": 2]]
        for node in exitNodes {
            let trimmed = node.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            patches.append(["action": 0, "node": ["ip": ["Ipv4": ["addr": try ipv4Address(trimmed)]]]])
        }
        return patches
    }

    static func mappedListenerListPatch(_ listeners: [String]) throws -> [[String: Any]] {
        var patches: [[String: Any]] = [["action": 2]]
        for listener in listeners {
            let trimmed = listener.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            patches.append(["action": 0, "url": ["url": trimmed]])
        }
        return patches
    }

    static func ipv4InetPayload(ip: String, networkLength: Int) throws -> [String: Any] {
        ["address": ["addr": try ipv4Address(ip)], "network_length": networkLength]
    }

    static func parseCIDR(_ cidr: String) throws -> (String, Int) {
        let parts = cidr.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let ip = String(parts.first ?? "")
        let prefix = parts.count > 1 ? Int(String(parts[1])) ?? 24 : 24
        return (ip, prefix)
    }

}

public enum EasyTierRPCError: LocalizedError, Equatable, Sendable {
    case invalidInstanceID(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidInstanceID(instanceID):
            "Invalid EasyTier instance id: \(instanceID)"
        }
    }
}

private struct InstanceRequestPayload: Encodable {
    var instance: InstanceIdentifierPayload
}

private struct InstanceIdentifierPayload: Encodable {
    var selector: InstanceIdentifierSelectorPayload

    init(id: RPCUUID) {
        self.selector = InstanceIdentifierSelectorPayload(id: id)
    }
}

private struct InstanceIdentifierSelectorPayload: Encodable {
    var id: RPCUUID

    enum CodingKeys: String, CodingKey {
        case id = "Id"
    }
}

private struct RPCUUID: Encodable {
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
