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
        try await patchConfig(instanceID: instanceID, runtimePatch: Self.hostnamePatch(hostname)) { config in
            config["hostname"] = hostname
        }
    }

    @discardableResult
    public func patchPortForwards(instanceID: String, portForwards: [PortForwardConfig]) async throws -> String {
        let encodedPortForwards = try Self.jsonObject(portForwards)
        let runtimePatch = try Self.portForwardsPatch(portForwards)
        return try await patchConfig(instanceID: instanceID, runtimePatch: runtimePatch) { config in
            config["port_forwards"] = encodedPortForwards
        }
    }

    @discardableResult
    private func patchConfig(instanceID: String, runtimePatch: [String: Any], mutate: (inout [String: Any]) throws -> Void) async throws -> String {
        let runtimePayload = try Self.patchConfigPayload(instanceID: instanceID, patch: runtimePatch)
        var reloadCallStarted = false
        do {
            let response = try await getConfig(instanceID: instanceID)
            let payload = try Self.runNetworkInstancePayload(instanceID: instanceID, getConfigResponse: response, mutate: mutate)
            reloadCallStarted = true
            return try await call(EasyTierRPCRequest(
                service: Self.webClientService,
                method: "run_network_instance",
                payload: payload
            ))
        } catch {
            if reloadCallStarted, !Self.canFallbackToRuntimePatch(after: error) {
                throw EasyTierRPCError.reloadWriteUnconfirmed(error.localizedDescription)
            }
            return try await call(EasyTierRPCRequest(
                service: Self.configService,
                method: "patch_config",
                payload: runtimePayload
            ))
        }
    }

    public static func getConfig(rpcURL: URL, instanceID: String, privilegedClient: PrivilegedEasyTierClient = PrivilegedEasyTierClient()) async throws -> String {
        try await EasyTierRemoteRPCClient(rpcURL: rpcURL, privilegedClient: privilegedClient).getConfig(instanceID: instanceID)
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
        return ["port_forwards": patches]
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

    private static func socketAddress(ip: String, port: Int) throws -> [String: Any] {
        guard (1...65_535).contains(port) else {
            throw EasyTierCoreError.invalidResponse("port forward port is out of range")
        }
        return ["ipv4": ["addr": try ipv4Address(ip)], "port": port]
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

    private static func canFallbackToRuntimePatch(after error: Error) -> Bool {
        if let error = error as? EasyTierCoreError,
           case let .operationFailed(message) = error {
            return message.contains("RPC Error:")
        }
        if let error = error as? PrivilegedHelperError,
           case let .helperReported(payload) = error {
            return payload.code == "callJSONRPCFailed" && payload.message.contains("RPC Error:")
        }
        return false
    }
}

public enum EasyTierRPCError: LocalizedError, Equatable, Sendable {
    case invalidInstanceID(String)
    case reloadWriteUnconfirmed(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidInstanceID(instanceID):
            "Invalid EasyTier instance id: \(instanceID)"
        case let .reloadWriteUnconfirmed(message):
            "Remote EasyTier reload was sent but could not be confirmed: \(message)"
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
