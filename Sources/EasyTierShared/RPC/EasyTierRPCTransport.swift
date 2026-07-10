import Foundation

package struct EasyTierRPCRequest: Equatable, Sendable {
    package var service: String
    package var method: String
    package var domain: String?
    package var payload: String

    package init(service: String, method: String, domain: String? = nil, payload: String) {
        self.service = service
        self.method = method
        self.domain = domain
        self.payload = payload
    }
}

package protocol EasyTierRPCTransport: Sendable {
    func call(_ request: EasyTierRPCRequest) async throws -> String
}

package struct EasyTierRemoteRPCClient: Sendable {
    private let transport: any EasyTierRPCTransport

    package init(transport: any EasyTierRPCTransport) {
        self.transport = transport
    }

    package init(
        rpcURL: URL,
        client: any EasyTierCoreClient = PrivilegedEasyTierClient()
    ) {
        self.init(transport: EasyTierCoreRPCTransport(client: client, rpcURL: rpcURL))
    }

    package func call(_ request: EasyTierRPCRequest) async throws -> String {
        try await transport.call(request)
    }

    package func getConfig(instanceID: String) async throws -> String {
        try await call(EasyTierRPCRequest(
            service: Self.configService,
            method: "get_config",
            payload: try Self.instancePayload(instanceID: instanceID)
        ))
    }

    package func getConfigParsed(instanceID: String) async throws -> NetworkConfig {
        let response = try await getConfig(instanceID: instanceID)
        return try Self.parseGetConfigResponse(response)
    }

    package func listPortForwards(instanceID: String) async throws -> String {
        try await call(EasyTierRPCRequest(
            service: Self.portForwardService,
            method: "list_port_forward",
            payload: try Self.instancePayload(instanceID: instanceID)
        ))
    }

    @discardableResult
    package func patchHostname(instanceID: String, hostname: String) async throws -> String {
        try await patchConfig(instanceID: instanceID, patch: .hostname(hostname))
    }

    @discardableResult
    package func patchPortForwards(instanceID: String, portForwards: [PortForwardConfig]) async throws -> String {
        let runtimePatch = try Self.portForwardsPatch(portForwards)
        return try await patchConfig(instanceID: instanceID, patch: runtimePatch)
    }

    @discardableResult
    package func patchPortForwardRemove(instanceID: String, portForward: PortForwardConfig) async throws -> String {
        let runtimePatch = try Self.portForwardRemovePatch(portForward)
        return try await patchConfig(instanceID: instanceID, patch: runtimePatch)
    }

    package func listPortForwardsParsed(instanceID: String) async throws -> [PortForwardConfig] {
        let response = try await listPortForwards(instanceID: instanceID)
        return try Self.parseListPortForwardsResponse(response)
    }

    @discardableResult
    private func patchConfig(instanceID: String, patch: InstanceConfigPatchPayload) async throws -> String {
        let runtimePayload = try Self.patchConfigPayload(instanceID: instanceID, patch: patch)
        return try await call(EasyTierRPCRequest(
            service: Self.configService,
            method: "patch_config",
            payload: runtimePayload
        ))
    }

    @discardableResult
    package func applyConfigPatch(instanceID: String, config: NetworkConfig, original: NetworkConfig) async throws -> String {
        let patch = try Self.configPatch(config: config, original: original)
        guard patch.hasChanges else { return "" }
        return try await patchConfig(instanceID: instanceID, patch: patch)
    }

}

extension EasyTierRemoteRPCClient {
    static let configService = "api.config.ConfigRpcService"
    static let portForwardService = "api.instance.PortForwardManageRpcService"

    static func instancePayload(instanceID: String) throws -> String {
        try encodePayload(InstanceRequestPayload(instance: instanceIdentifier(instanceID: instanceID)))
    }

    private static func patchConfigPayload(instanceID: String, patch: InstanceConfigPatchPayload) throws -> String {
        try encodePayload(PatchConfigRequestPayload(
            patch: patch,
            instance: instanceIdentifier(instanceID: instanceID)
        ))
    }

    private static func instanceIdentifier(instanceID: String) throws -> InstanceIdentifierPayload {
        guard let uuid = UUID(uuidString: instanceID) else {
            throw EasyTierRPCError.invalidInstanceID(instanceID)
        }
        return InstanceIdentifierPayload(id: RPCUUID(uuid: uuid))
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

    private static func portForwardsPatch(_ portForwards: [PortForwardConfig]) throws -> InstanceConfigPatchPayload {
        var patches: [PortForwardPatchPayload] = [.clear()]
        for portForward in portForwards {
            patches.append(.add(try portForwardPatchConfig(portForward)))
        }
        return InstanceConfigPatchPayload(portForwards: patches)
    }

    private static func portForwardRemovePatch(_ portForward: PortForwardConfig) throws -> InstanceConfigPatchPayload {
        InstanceConfigPatchPayload(portForwards: [.remove(try portForwardPatchConfig(portForward))])
    }

    private static func portForwardPatchConfig(_ portForward: PortForwardConfig) throws -> PortForwardConfigPayload {
        let socketType: Int
        switch portForward.proto.lowercased() {
        case "tcp": socketType = 0
        case "udp": socketType = 1
        default: throw EasyTierCoreError.invalidResponse("port forward protocol must be tcp or udp")
        }
        return PortForwardConfigPayload(
            bindAddr: try socketAddress(ip: portForward.bind_ip, port: portForward.bind_port),
            dstAddr: try socketAddress(ip: portForward.dst_ip, port: portForward.dst_port),
            socketType: socketType
        )
    }

    package static func parseListPortForwardsResponse(_ response: String) throws -> [PortForwardConfig] {
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

    private static func socketAddress(ip: String, port: Int) throws -> SocketAddressPayload {
        guard (1...65_535).contains(port) else {
            throw EasyTierCoreError.invalidResponse("port forward port is out of range")
        }
        return SocketAddressPayload(ipv4: try ipv4AddressPayload(ip), port: port)
    }

    private static func ipv4AddressPayload(_ value: String) throws -> IPv4AddressPayload {
        IPv4AddressPayload(addr: try ipv4Address(value))
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

    private static func configPatch(config: NetworkConfig, original: NetworkConfig) throws -> InstanceConfigPatchPayload {
        var patch = InstanceConfigPatchPayload()
        var hasChanges = false

        if config.hostname != original.hostname {
            patch.hostname = config.hostname ?? ""
            hasChanges = true
        }

        if config.virtual_ipv4 != original.virtual_ipv4 || config.network_length != original.network_length {
            if !config.virtual_ipv4.isEmpty {
                patch.ipv4 = try ipv4InetPayload(ip: config.virtual_ipv4, networkLength: config.network_length)
                hasChanges = true
            }
        }

        if config.ipv6_public_addr_auto != original.ipv6_public_addr_auto {
            patch.ipv6PublicAddrAuto = config.ipv6_public_addr_auto ?? false
            hasChanges = true
        }

        if config.port_forwards != original.port_forwards {
            patch.portForwards = try portForwardsListPatch(config.port_forwards)
            hasChanges = true
        }

        if config.routes != original.routes {
            patch.routes = try routeListPatch(config.routes)
            hasChanges = true
        }

        if config.exit_nodes != original.exit_nodes {
            patch.exitNodes = try exitNodeListPatch(config.exit_nodes)
            hasChanges = true
        }

        if config.mapped_listeners != original.mapped_listeners {
            patch.mappedListeners = mappedListenerListPatch(config.mapped_listeners)
            hasChanges = true
        }

        return hasChanges ? patch : .empty
    }

    private static func portForwardsListPatch(_ portForwards: [PortForwardConfig]) throws -> [PortForwardPatchPayload] {
        var patches: [PortForwardPatchPayload] = [.clear()]
        for portForward in portForwards {
            patches.append(.add(try portForwardPatchConfig(portForward)))
        }
        return patches
    }

    private static func routeListPatch(_ routes: [String]) throws -> [RoutePatchPayload] {
        var patches: [RoutePatchPayload] = [.clear()]
        for route in routes {
            let trimmed = route.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let (ip, prefix) = try parseCIDR(trimmed)
            patches.append(.add(try ipv4InetPayload(ip: ip, networkLength: prefix)))
        }
        return patches
    }

    private static func exitNodeListPatch(_ exitNodes: [String]) throws -> [ExitNodePatchPayload] {
        var patches: [ExitNodePatchPayload] = [.clear()]
        for node in exitNodes {
            let trimmed = node.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            patches.append(.add(IPAddressPayload(ipv4: try ipv4AddressPayload(trimmed))))
        }
        return patches
    }

    private static func mappedListenerListPatch(_ listeners: [String]) -> [URLPatchPayload] {
        var patches: [URLPatchPayload] = [.clear()]
        for listener in listeners {
            let trimmed = listener.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            patches.append(.add(trimmed))
        }
        return patches
    }

    private static func ipv4InetPayload(ip: String, networkLength: Int) throws -> IPv4InetPayload {
        IPv4InetPayload(address: try ipv4AddressPayload(ip), networkLength: networkLength)
    }

    private static func parseCIDR(_ cidr: String) throws -> (String, Int) {
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
