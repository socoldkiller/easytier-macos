import Foundation
import Testing
@testable import EasyTierShared

private actor SpyRPCTransport: EasyTierRPCTransport {
    private var calls: [EasyTierRPCRequest] = []
    private var responses: [String]

    init(response: String = #"{"ok":true}"#) {
        self.responses = [response]
    }

    init(responses: [String]) {
        self.responses = responses
    }

    func call(_ request: EasyTierRPCRequest) async throws -> String {
        calls.append(request)
        return responses.isEmpty ? #"{"ok":true}"# : responses.removeFirst()
    }

    func firstCall() -> EasyTierRPCRequest? {
        calls.first
    }

    func allCalls() -> [EasyTierRPCRequest] {
        calls
    }
}

private actor ThrowingRPCTransport: EasyTierRPCTransport {
    private var calls: [EasyTierRPCRequest] = []
    private let error: Error

    init(error: Error) {
        self.error = error
    }

    func call(_ request: EasyTierRPCRequest) async throws -> String {
        calls.append(request)
        throw error
    }

    func allCalls() -> [EasyTierRPCRequest] {
        calls
    }
}

private actor SpyCoreClient: EasyTierCoreClient {
    struct RPCCall: Equatable, Sendable {
        var clientID: String
        var url: URL
        var service: String
        var method: String
        var domain: String?
        var payload: String
    }

    private var rpcCalls: [RPCCall] = []

    func validate(toml _: String) async throws {}
    func run(toml _: String) async throws {}
    func stop(instanceNames _: [String]) async throws {}
    func retain(instanceNames _: [String]) async throws {}
    func collectNetworkInfos() async throws -> [String: NetworkInstanceRunningInfo] { [:] }
    func configureRPCPortal(_: String?, whitelist _: [String]?) async throws {}

    func callJSONRPC(
        clientID: String,
        url: URL,
        service: String,
        method: String,
        domain: String?,
        payload: String
    ) async throws -> String {
        rpcCalls.append(RPCCall(
            clientID: clientID,
            url: url,
            service: service,
            method: method,
            domain: domain,
            payload: payload
        ))
        return #"{"ok":true}"#
    }

    func allRPCCalls() -> [RPCCall] {
        rpcCalls
    }
}

@Test func remoteClientForwardsGenericRPCRequest() async throws {
    let transport = SpyRPCTransport(response: #"{"ok":1}"#)
    let client = EasyTierRemoteRPCClient(transport: transport)
    let request = EasyTierRPCRequest(service: "svc", method: "method", domain: "domain", payload: #"{"x":1}"#)

    let response = try await client.call(request)

    #expect(response == #"{"ok":1}"#)
    #expect(await transport.firstCall() == request)
}

@Test func coreRPCTransportForwardsURLAndUsesOneStableClientID() async throws {
    let core = SpyCoreClient()
    let url = try #require(URL(string: "tcp://127.0.0.1:15888"))
    let transport = EasyTierCoreRPCTransport(client: core, rpcURL: url)
    let request = EasyTierRPCRequest(service: "svc", method: "method", domain: "domain", payload: #"{"x":1}"#)

    let response = try await transport.call(request)
    let calls = await core.allRPCCalls()

    #expect(response == #"{"ok":true}"#)
    #expect(calls.count == 1)
    #expect(calls.first?.url == url)
    #expect(calls.first?.clientID == transport.clientID)
    #expect(calls.first?.clientID.hasPrefix("rpc-") == true)
    #expect(calls.first?.service == request.service)
    #expect(calls.first?.method == request.method)
    #expect(calls.first?.domain == request.domain)
    #expect(calls.first?.payload == request.payload)
}

@Test func patchHostnameUsesRuntimePatchDirectly() async throws {
    let transport = SpyRPCTransport(response: #"{"ok":true}"#)
    let client = EasyTierRemoteRPCClient(transport: transport)

    let response = try await client.patchHostname(instanceID: "11111111-2222-3333-4444-555555555555", hostname: "edge-mac")
    let calls = await transport.allCalls()

    #expect(response == #"{"ok":true}"#)
    #expect(calls.map(\.method) == ["patch_config"])
    guard let call = calls.first else {
        Issue.record("expected a runtime patch call")
        return
    }

    #expect(call.service == "api.config.ConfigRpcService")
    #expect(call.method == "patch_config")
    #expect(call.domain == nil)

    let object = try rpcPayloadObject(call.payload)
    let patch = object["patch"] as? [String: Any]
    #expect(patch?["hostname"] as? String == "edge-mac")
    #expect(patch?.keys.contains("ipv4") == false)
    #expect((patch?["port_forwards"] as? [Any])?.isEmpty == true)
    #expect((patch?["proxy_networks"] as? [Any])?.isEmpty == true)
    #expect((patch?["routes"] as? [Any])?.isEmpty == true)
    #expect((patch?["exit_nodes"] as? [Any])?.isEmpty == true)
    #expect((patch?["mapped_listeners"] as? [Any])?.isEmpty == true)
    #expect((patch?["connectors"] as? [Any])?.isEmpty == true)

    let id = rpcInstanceID(in: object)
    #expect(id?["part1"] as? Int == 0x11111111)
    #expect(id?["part2"] as? Int == 0x22223333)
    #expect(id?["part3"] as? Int == 0x44445555)
    #expect(id?["part4"] as? Int == 0x55555555)
}

@Test func readOnlyRPCWrappersUseExpectedServicesAndPayloads() async throws {
    let transport = SpyRPCTransport(response: #"{"value":1}"#)
    let client = EasyTierRemoteRPCClient(transport: transport)

    let configResponse = try await client.getConfig(instanceID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
    #expect(configResponse == #"{"value":1}"#)

    guard let call = await transport.firstCall() else {
        Issue.record("expected an RPC call")
        return
    }

    #expect(call.service == "api.config.ConfigRpcService")
    #expect(call.method == "get_config")
    let object = try rpcPayloadObject(call.payload)
    let id = rpcInstanceID(in: object)
    #expect(id?["part1"] as? Int == 0xaaaaaaaa)
    #expect(id?["part2"] as? Int == 0xbbbbcccc)
    #expect(id?["part3"] as? Int == 0xddddeeee)
    #expect(id?["part4"] as? Int == 0xeeeeeeee)
}

@Test func getConfigParsedTreatsNullableRemoteConfigFieldsAsDefaults() async throws {
    let instanceID = "11111111-2222-3333-4444-555555555555"
    var encodedConfig = try jsonObject(from: JSONEncoder().encode(NetworkConfig(
        instance_id: instanceID,
        hostname: "windy",
        network_name: "office",
        public_server_url: "tcp://public.easytier.top:11010",
        peer_urls: ["tcp://10.0.0.1:11010"],
        enable_vpn_portal: true,
        vpn_portal_listen_port: 44_444
    )))
    encodedConfig["public_server_url"] = NSNull()
    encodedConfig["peer_urls"] = NSNull()
    encodedConfig["proxy_cidrs"] = NSNull()
    encodedConfig["enable_vpn_portal"] = NSNull()
    encodedConfig["vpn_portal_listen_port"] = NSNull()
    encodedConfig["enable_manual_routes"] = NSNull()
    encodedConfig["routes"] = NSNull()

    let response = try jsonString(["config": encodedConfig])
    let transport = SpyRPCTransport(response: response)
    let client = EasyTierRemoteRPCClient(transport: transport)

    let config = try await client.getConfigParsed(instanceID: instanceID)

    #expect(config.instance_id == instanceID)
    #expect(config.hostname == "windy")
    #expect(config.public_server_url == "")
    #expect(config.peer_urls == [])
    #expect(config.proxy_cidrs == [])
    #expect(config.enable_vpn_portal == false)
    #expect(config.vpn_portal_listen_port == 22_022)
    #expect(config.enable_manual_routes == false)
    #expect(config.routes == [])
}

@Test func listPortForwardsUsesPortForwardService() async throws {
    let transport = SpyRPCTransport(response: #"{"cfgs":[]}"#)
    let client = EasyTierRemoteRPCClient(transport: transport)

    let response = try await client.listPortForwards(instanceID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")

    #expect(response == #"{"cfgs":[]}"#)
    guard let call = await transport.firstCall() else {
        Issue.record("expected an RPC call")
        return
    }

    #expect(call.service == "api.instance.PortForwardManageRpcService")
    #expect(call.method == "list_port_forward")
    #expect(call.domain == nil)
    let object = try rpcPayloadObject(call.payload)
    let id = rpcInstanceID(in: object)
    #expect(id?["part1"] as? Int == 0xaaaaaaaa)
    #expect(id?["part2"] as? Int == 0xbbbbcccc)
    #expect(id?["part3"] as? Int == 0xddddeeee)
    #expect(id?["part4"] as? Int == 0xeeeeeeee)
}

@Test func patchPortForwardsUsesRuntimePatchDirectly() async throws {
    let transport = SpyRPCTransport()
    let client = EasyTierRemoteRPCClient(transport: transport)

    try await client.patchPortForwards(
        instanceID: "11111111-2222-3333-4444-555555555555",
        portForwards: [PortForwardConfig(bind_ip: "0.0.0.0", bind_port: 8080, dst_ip: "10.126.126.2", dst_port: 80, proto: "tcp")]
    )
    let calls = await transport.allCalls()

    #expect(calls.map(\.method) == ["patch_config"])
    guard let call = calls.first else {
        Issue.record("expected a runtime patch call")
        return
    }

    #expect(call.service == "api.config.ConfigRpcService")
    #expect(call.domain == nil)
    let object = try rpcPayloadObject(call.payload)
    let patch = object["patch"] as? [String: Any]
    #expect(patch?.keys.contains("ipv4") == false)
    let patches = patch?["port_forwards"] as? [[String: Any]]
    #expect(patches?.count == 2)
    #expect(patches?.first?["action"] as? Int == 2)
    let add = patches?.last
    #expect(add?["action"] as? Int == 0)
    let cfg = add?["cfg"] as? [String: Any]
    #expect(cfg?["socket_type"] as? Int == 0)
    let bind = cfg?["bind_addr"] as? [String: Any]
    #expect(bind?["port"] as? Int == 8080)
    let bindIPv4Container = bind?["ip"] as? [String: Any]
    let bindIPv4Addr = bindIPv4Container?["Ipv4"] as? [String: Any]
    #expect(bindIPv4Addr?["addr"] as? Int == 0)
    let dst = cfg?["dst_addr"] as? [String: Any]
    #expect(dst?["port"] as? Int == 80)
    let dstIPv4Container = dst?["ip"] as? [String: Any]
    let dstIPv4Addr = dstIPv4Container?["Ipv4"] as? [String: Any]
    #expect(dstIPv4Addr?["addr"] as? Int == 0x0a7e7e02)
}

@Test func applyConfigPatchIncludesRequiredRepeatedPatchFields() async throws {
    let transport = SpyRPCTransport()
    let client = EasyTierRemoteRPCClient(transport: transport)
    let original = NetworkConfig(
        instance_id: "11111111-2222-3333-4444-555555555555",
        network_name: "office"
    )
    var config = original
    config.port_forwards = [
        PortForwardConfig(bind_ip: "0.0.0.0", bind_port: 80, dst_ip: "10.0.64.16", dst_port: 80, proto: "tcp"),
    ]

    try await client.applyConfigPatch(instanceID: original.instance_id, config: config, original: original)
    let calls = await transport.allCalls()

    #expect(calls.map(\.method) == ["patch_config"])
    let object = try rpcPayloadObject(calls[0].payload)
    let patch = object["patch"] as? [String: Any]
    #expect((patch?["proxy_networks"] as? [Any])?.isEmpty == true)
    #expect((patch?["routes"] as? [Any])?.isEmpty == true)
    #expect((patch?["exit_nodes"] as? [Any])?.isEmpty == true)
    #expect((patch?["mapped_listeners"] as? [Any])?.isEmpty == true)
    #expect((patch?["connectors"] as? [Any])?.isEmpty == true)
    let portForwards = patch?["port_forwards"] as? [[String: Any]]
    #expect(portForwards?.count == 2)
    #expect(portForwards?.first?["action"] as? Int == 2)
}

@Test func applyConfigPatchEncodesListPatchSchemas() async throws {
    let transport = SpyRPCTransport()
    let client = EasyTierRemoteRPCClient(transport: transport)
    let original = NetworkConfig(
        instance_id: "11111111-2222-3333-4444-555555555555",
        network_name: "office"
    )
    var config = original
    config.routes = ["10.0.64.0/24"]
    config.exit_nodes = ["10.0.64.1"]
    config.mapped_listeners = ["tcp://0.0.0.0:11010"]

    try await client.applyConfigPatch(instanceID: original.instance_id, config: config, original: original)
    let calls = await transport.allCalls()

    #expect(calls.map(\.method) == ["patch_config"])
    let object = try rpcPayloadObject(calls[0].payload)
    let patch = object["patch"] as? [String: Any]

    let routes = patch?["routes"] as? [[String: Any]]
    #expect(routes?.count == 2)
    #expect(routes?.first?["action"] as? Int == 2)
    let routeCIDR = routes?.last?["cidr"] as? [String: Any]
    let routeAddress = routeCIDR?["address"] as? [String: Any]
    #expect(routeAddress?["addr"] as? Int == 0x0a004000)
    #expect(routeCIDR?["network_length"] as? Int == 24)

    let exitNodes = patch?["exit_nodes"] as? [[String: Any]]
    #expect(exitNodes?.count == 2)
    #expect(exitNodes?.first?["action"] as? Int == 2)
    let node = exitNodes?.last?["node"] as? [String: Any]
    let nodeIP = node?["ip"] as? [String: Any]
    let nodeIPv4 = nodeIP?["Ipv4"] as? [String: Any]
    #expect(nodeIPv4?["addr"] as? Int == 0x0a004001)

    let mappedListeners = patch?["mapped_listeners"] as? [[String: Any]]
    #expect(mappedListeners?.count == 2)
    #expect(mappedListeners?.first?["action"] as? Int == 2)
    let listenerURL = mappedListeners?.last?["url"] as? [String: Any]
    #expect(listenerURL?["url"] as? String == "tcp://0.0.0.0:11010")
}

@Test func patchPortForwardsRuntimePatchEncodesUdpAndUnspecifiedBind() async throws {
    let transport = SpyRPCTransport()
    let client = EasyTierRemoteRPCClient(transport: transport)

    try await client.patchPortForwards(
        instanceID: "11111111-2222-3333-4444-555555555555",
        portForwards: [PortForwardConfig(bind_ip: "0.0.0.0", bind_port: 8080, dst_ip: "10.126.126.2", dst_port: 80, proto: "udp")]
    )
    let calls = await transport.allCalls()

    #expect(calls.map(\.method) == ["patch_config"])
    let object = try rpcPayloadObject(calls[0].payload)
    let patch = object["patch"] as? [String: Any]
    let patches = patch?["port_forwards"] as? [[String: Any]]
    #expect(patches?.count == 2)
    #expect(patches?.first?["action"] as? Int == 2)
    let add = patches?.last
    #expect(add?["action"] as? Int == 0)
    let cfg = add?["cfg"] as? [String: Any]
    #expect(cfg?["socket_type"] as? Int == 1)
    let bind = cfg?["bind_addr"] as? [String: Any]
    #expect(bind?["port"] as? Int == 8080)
    let bindIPv4Container = bind?["ip"] as? [String: Any]
    let bindIPv4Addr = bindIPv4Container?["Ipv4"] as? [String: Any]
    #expect(bindIPv4Addr?["addr"] as? Int == 0)
}

@Test func patchHostnamePropagatesRuntimePatchFailureWithoutReloading() async throws {
    let transport = ThrowingRPCTransport(error: EasyTierCoreError.operationFailed("Remote EasyTier RPC request timed out"))
    let client = EasyTierRemoteRPCClient(transport: transport)

    do {
        try await client.patchHostname(instanceID: "11111111-2222-3333-4444-555555555555", hostname: "new-host")
        Issue.record("runtime patch failure should be propagated")
    } catch EasyTierCoreError.operationFailed(let message) {
        #expect(message.contains("timed out"))
    } catch {
        Issue.record("unexpected error: \(error)")
    }

    let calls = await transport.allCalls()

    #expect(calls.map(\.method) == ["patch_config"])
}

@Test func rpcWrapperRejectsInvalidInstanceIDBeforeCallingTransport() async throws {
    let transport = SpyRPCTransport()
    let client = EasyTierRemoteRPCClient(transport: transport)

    do {
        _ = try await client.getConfig(instanceID: "not-a-uuid")
        Issue.record("invalid UUID should fail before RPC call")
    } catch EasyTierRPCError.invalidInstanceID(let value) {
        #expect(value == "not-a-uuid")
    } catch {
        Issue.record("unexpected error: \(error)")
    }

    #expect(await transport.firstCall() == nil)
}

private func rpcPayloadObject(_ payload: String) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
        throw EasyTierCoreError.invalidResponse("RPC payload is not a JSON object")
    }
    return object
}

private func jsonObject(from data: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw EasyTierCoreError.invalidResponse("JSON value is not an object")
    }
    return object
}

private func jsonString(_ object: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    guard let string = String(data: data, encoding: .utf8) else {
        throw EasyTierCoreError.invalidResponse("JSON data is not UTF-8")
    }
    return string
}

private func rpcInstanceID(in object: [String: Any]) -> [String: Any]? {
    let instance = object["instance"] as? [String: Any]
    let selector = instance?["selector"] as? [String: Any]
    return selector?["Id"] as? [String: Any]
}
