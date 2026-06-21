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

@Test func remoteClientForwardsGenericRPCRequest() async throws {
    let transport = SpyRPCTransport(response: #"{"ok":1}"#)
    let client = EasyTierRemoteRPCClient(transport: transport)
    let request = EasyTierRPCRequest(service: "svc", method: "method", domain: "domain", payload: #"{"x":1}"#)

    let response = try await client.call(request)

    #expect(response == #"{"ok":1}"#)
    #expect(await transport.firstCall() == request)
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

@Test func runNetworkInstancePayloadStillBuildsPersistentReloadPayload() async throws {
    let response = #"{"config":{"instance_id":"11111111-2222-3333-4444-555555555555","network_name":"office","hostname":"old-host","peer_urls":["tcp://10.0.0.1:11010"]}}"#
    let payload = try EasyTierRemoteRPCClient.runNetworkInstancePayload(
        instanceID: "11111111-2222-3333-4444-555555555555",
        getConfigResponse: response
    ) { config in
        config["hostname"] = "new-host"
    }

    let object = try rpcPayloadObject(payload)
    #expect(object["overwrite"] as? Bool == true)
    #expect(object["source"] as? Int == 1)
    let config = object["config"] as? [String: Any]
    #expect(config?["hostname"] as? String == "new-host")
    #expect(config?["network_name"] as? String == "office")
    #expect(config?["peer_urls"] as? [String] == ["tcp://10.0.0.1:11010"])
    let id = object["inst_id"] as? [String: Any]
    #expect(id?["part1"] as? Int == 0x11111111)
    #expect(id?["part2"] as? Int == 0x22223333)
    #expect(id?["part3"] as? Int == 0x44445555)
    #expect(id?["part4"] as? Int == 0x55555555)
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
    let bindIPv4 = bind?["ipv4"] as? [String: Any]
    #expect(bindIPv4?["addr"] as? Int == 0)
    let dst = cfg?["dst_addr"] as? [String: Any]
    #expect(dst?["port"] as? Int == 80)
    let dstIPv4 = dst?["ipv4"] as? [String: Any]
    #expect(dstIPv4?["addr"] as? Int == 0x0a7e7e02)
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
    let bindIPv4 = bind?["ipv4"] as? [String: Any]
    #expect(bindIPv4?["addr"] as? Int == 0)
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

private func rpcInstanceID(in object: [String: Any]) -> [String: Any]? {
    let instance = object["instance"] as? [String: Any]
    let selector = instance?["selector"] as? [String: Any]
    return selector?["Id"] as? [String: Any]
}
