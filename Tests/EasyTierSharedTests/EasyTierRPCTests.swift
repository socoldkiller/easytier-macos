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

private actor RunNetworkFailingRPCTransport: EasyTierRPCTransport {
    private var calls: [EasyTierRPCRequest] = []
    private let message: String

    init(message: String) {
        self.message = message
    }

    func call(_ request: EasyTierRPCRequest) async throws -> String {
        calls.append(request)
        if request.service == "api.manage.WebClientService" {
            throw EasyTierCoreError.operationFailed(message)
        }
        if request.method == "get_config" {
            return #"{"config":{"network_name":"office","hostname":"old-host"}}"#
        }
        return #"{"ok":true}"#
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

@Test func patchHostnameFallsBackToRuntimePatchWhenPersistentWriteIsRejected() async throws {
    let transport = RunNetworkFailingRPCTransport(message: "RPC Error: instance config rejected")
    let client = EasyTierRemoteRPCClient(transport: transport)

    let response = try await client.patchHostname(instanceID: "11111111-2222-3333-4444-555555555555", hostname: "edge-mac")
    let calls = await transport.allCalls()

    #expect(response == #"{"ok":true}"#)
    #expect(calls.map(\.method) == ["get_config", "run_network_instance", "patch_config"])
    guard let call = calls.last else {
        Issue.record("expected a runtime patch call")
        return
    }

    #expect(call.service == "api.config.ConfigRpcService")
    #expect(call.method == "patch_config")
    #expect(call.domain == nil)

    let object = try rpcPayloadObject(call.payload)
    let patch = object["patch"] as? [String: Any]
    #expect(patch?["hostname"] as? String == "edge-mac")
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

@Test func patchHostnameBuildsRunNetworkInstancePayload() async throws {
    let transport = SpyRPCTransport(responses: [
        #"{"config":{"instance_id":"11111111-2222-3333-4444-555555555555","network_name":"office","hostname":"old-host","peer_urls":["tcp://10.0.0.1:11010"]}}"#,
        #"{"ok":true}"#,
    ])
    let client = EasyTierRemoteRPCClient(transport: transport)

    try await client.patchHostname(instanceID: "11111111-2222-3333-4444-555555555555", hostname: "new-host")
    let calls = await transport.allCalls()

    #expect(calls.count == 2)
    #expect(calls[0].service == "api.config.ConfigRpcService")
    #expect(calls[0].method == "get_config")
    #expect(calls[1].service == "api.manage.WebClientService")
    #expect(calls[1].method == "run_network_instance")

    let object = try rpcPayloadObject(calls[1].payload)
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

@Test func patchPortForwardsBuildsRunNetworkInstancePayload() async throws {
    let transport = SpyRPCTransport(responses: [
        #"{"config":{"network_name":"office","hostname":"edge","port_forwards":[]}}"#,
        #"{"ok":true}"#,
    ])
    let client = EasyTierRemoteRPCClient(transport: transport)

    try await client.patchPortForwards(
        instanceID: "11111111-2222-3333-4444-555555555555",
        portForwards: [PortForwardConfig(bind_ip: "0.0.0.0", bind_port: 8080, dst_ip: "10.126.126.2", dst_port: 80, proto: "tcp")]
    )
    let calls = await transport.allCalls()

    #expect(calls.map(\.method) == ["get_config", "run_network_instance"])
    let object = try rpcPayloadObject(calls[1].payload)
    let config = object["config"] as? [String: Any]
    let forwards = config?["port_forwards"] as? [[String: Any]]
    #expect(forwards?.count == 1)
    #expect(forwards?.first?["bind_ip"] as? String == "0.0.0.0")
    #expect(forwards?.first?["bind_port"] as? Int == 8080)
    #expect(forwards?.first?["dst_ip"] as? String == "10.126.126.2")
    #expect(forwards?.first?["dst_port"] as? Int == 80)
    #expect(forwards?.first?["proto"] as? String == "tcp")
    #expect(forwards?.first?["id"] == nil)
}

@Test func patchPortForwardsFallsBackToRuntimePatchWhenPersistentWriteIsRejected() async throws {
    let transport = RunNetworkFailingRPCTransport(message: "RPC Error: instance config rejected")
    let client = EasyTierRemoteRPCClient(transport: transport)

    try await client.patchPortForwards(
        instanceID: "11111111-2222-3333-4444-555555555555",
        portForwards: [PortForwardConfig(bind_ip: "0.0.0.0", bind_port: 8080, dst_ip: "10.126.126.2", dst_port: 80, proto: "udp")]
    )
    let calls = await transport.allCalls()

    #expect(calls.map(\.method) == ["get_config", "run_network_instance", "patch_config"])
    let object = try rpcPayloadObject(calls[2].payload)
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

@Test func patchHostnameDoesNotPatchOldEndpointWhenReloadWriteIsUnconfirmed() async throws {
    let transport = RunNetworkFailingRPCTransport(message: "Remote EasyTier RPC request timed out")
    let client = EasyTierRemoteRPCClient(transport: transport)

    do {
        try await client.patchHostname(instanceID: "11111111-2222-3333-4444-555555555555", hostname: "new-host")
        Issue.record("reload write should be reported as unconfirmed")
    } catch EasyTierRPCError.reloadWriteUnconfirmed(let message) {
        #expect(message.contains("timed out"))
    } catch {
        Issue.record("unexpected error: \(error)")
    }

    let calls = await transport.allCalls()

    #expect(calls.map(\.method) == ["get_config", "run_network_instance"])
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
