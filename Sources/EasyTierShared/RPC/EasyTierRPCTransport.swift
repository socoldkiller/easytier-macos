import Foundation

public protocol EasyTierRPCTransport: Sendable {
    func call(service: String, method: String, domain: String?, payload: String) async throws -> String
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

    public func call(service: String, method: String, domain: String?, payload: String) async throws -> String {
        try await client.connectRPCClient(clientID: clientID, url: rpcURL)
        return try await client.callJSONRPC(clientID: clientID, service: service, method: method, domain: domain, payload: payload)
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

    public func getConfig(instanceID: String) async throws -> String {
        try await transport.call(
            service: Self.configService,
            method: "get_config",
            domain: nil,
            payload: try Self.instancePayload(instanceID: instanceID)
        )
    }

    public func listPeers(instanceID: String) async throws -> String {
        try await transport.call(
            service: Self.peerManageService,
            method: "list_peer",
            domain: nil,
            payload: try Self.instancePayload(instanceID: instanceID)
        )
    }

    @discardableResult
    public func patchHostname(instanceID: String, hostname: String) async throws -> String {
        try await transport.call(
            service: Self.configService,
            method: "patch_config",
            domain: nil,
            payload: try Self.patchHostnamePayload(instanceID: instanceID, hostname: hostname)
        )
    }

    @discardableResult
    public func persistHostname(instanceID: String, hostname: String) async throws -> String {
        let response = try await getConfig(instanceID: instanceID)
        return try await transport.call(
            service: Self.webClientService,
            method: "run_network_instance",
            domain: nil,
            payload: try Self.persistHostnamePayload(instanceID: instanceID, getConfigResponse: response, hostname: hostname)
        )
    }

    @discardableResult
    public func renameHostname(instanceID: String, hostname: String) async throws -> String {
        do {
            return try await persistHostname(instanceID: instanceID, hostname: hostname)
        } catch {
            return try await patchHostname(instanceID: instanceID, hostname: hostname)
        }
    }

    public static func getConfig(rpcURL: URL, instanceID: String, privilegedClient: PrivilegedEasyTierClient = PrivilegedEasyTierClient()) async throws -> String {
        try await EasyTierRemoteRPCClient(rpcURL: rpcURL, privilegedClient: privilegedClient).getConfig(instanceID: instanceID)
    }

    public static func listPeers(rpcURL: URL, instanceID: String, privilegedClient: PrivilegedEasyTierClient = PrivilegedEasyTierClient()) async throws -> String {
        try await EasyTierRemoteRPCClient(rpcURL: rpcURL, privilegedClient: privilegedClient).listPeers(instanceID: instanceID)
    }

    @discardableResult
    public static func patchHostname(rpcURL: URL, instanceID: String, hostname: String, privilegedClient: PrivilegedEasyTierClient = PrivilegedEasyTierClient()) async throws -> String {
        try await EasyTierRemoteRPCClient(rpcURL: rpcURL, privilegedClient: privilegedClient).patchHostname(instanceID: instanceID, hostname: hostname)
    }

    @discardableResult
    public static func persistHostname(rpcURL: URL, instanceID: String, hostname: String, privilegedClient: PrivilegedEasyTierClient = PrivilegedEasyTierClient()) async throws -> String {
        try await EasyTierRemoteRPCClient(rpcURL: rpcURL, privilegedClient: privilegedClient).persistHostname(instanceID: instanceID, hostname: hostname)
    }

    @discardableResult
    public static func renameHostname(rpcURL: URL, instanceID: String, hostname: String, privilegedClient: PrivilegedEasyTierClient = PrivilegedEasyTierClient()) async throws -> String {
        try await EasyTierRemoteRPCClient(rpcURL: rpcURL, privilegedClient: privilegedClient).renameHostname(instanceID: instanceID, hostname: hostname)
    }
}

extension EasyTierRemoteRPCClient {
    static let configService = "api.config.ConfigRpcService"
    static let peerManageService = "api.instance.PeerManageRpcService"
    static let webClientService = "api.manage.WebClientService"

    static func instancePayload(instanceID: String) throws -> String {
        try encodePayload(InstanceRequestPayload(instance: instanceIdentifier(instanceID: instanceID)))
    }

    static func patchHostnamePayload(instanceID: String, hostname: String) throws -> String {
        try encodePayload(PatchHostnameRequestPayload(
            patch: HostnamePatch(hostname: hostname),
            instance: instanceIdentifier(instanceID: instanceID)
        ))
    }

    static func persistHostnamePayload(instanceID: String, getConfigResponse: String, hostname: String) throws -> String {
        guard let data = getConfigResponse.data(using: .utf8),
              let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var config = response["config"] as? [String: Any]
        else {
            throw EasyTierCoreError.invalidResponse("RPC get_config response did not include a config object")
        }

        config["hostname"] = hostname
        let payload: [String: Any] = [
            "inst_id": try rpcUUIDPayload(instanceID: instanceID),
            "config": config,
            "overwrite": true,
            "source": 1,
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let json = String(data: payloadData, encoding: .utf8) else {
            throw EasyTierCoreError.invalidResponse("failed to encode persistent hostname payload as UTF-8")
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

private struct PatchHostnameRequestPayload: Encodable {
    var patch: HostnamePatch
    var instance: InstanceIdentifierPayload
}

private struct HostnamePatch: Encodable {
    var hostname: String
    var port_forwards: [EmptyPatch] = []
    var proxy_networks: [EmptyPatch] = []
    var routes: [EmptyPatch] = []
    var exit_nodes: [EmptyPatch] = []
    var mapped_listeners: [EmptyPatch] = []
    var connectors: [EmptyPatch] = []
}

private struct EmptyPatch: Encodable {
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
