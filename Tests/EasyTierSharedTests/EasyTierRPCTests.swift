import Foundation
import Testing
@testable import EasyTierShared

private struct RPCCall: Equatable, Sendable {
    var service: String
    var method: String
    var domain: String?
    var payload: String
}

private actor SpyRPCTransport: EasyTierRPCTransport {
    private var calls: [RPCCall] = []
    private var responses: [String]

    init(response: String = #"{"ok":true}"#) {
        self.responses = [response]
    }

    init(responses: [String]) {
        self.responses = responses
    }

    func call(service: String, method: String, domain: String?, payload: String) async throws -> String {
        calls.append(RPCCall(service: service, method: method, domain: domain, payload: payload))
        return responses.isEmpty ? #"{"ok":true}"# : responses.removeFirst()
    }

    func firstCall() -> RPCCall? {
        calls.first
    }

    func allCalls() -> [RPCCall] {
        calls
    }
}

private actor PersistFailingRPCTransport: EasyTierRPCTransport {
    private var calls: [RPCCall] = []

    func call(service: String, method: String, domain: String?, payload: String) async throws -> String {
        calls.append(RPCCall(service: service, method: method, domain: domain, payload: payload))
        if service == "api.manage.WebClientService" {
            throw EasyTierCoreError.operationFailed("instance is read-only")
        }
        if method == "get_config" {
            return #"{"config":{"network_name":"office","hostname":"old-host"}}"#
        }
        return #"{"ok":true}"#
    }

    func allCalls() -> [RPCCall] {
        calls
    }
}

@Test func patchHostnameBuildsExpectedRPCPayload() async throws {
    let transport = SpyRPCTransport()
    let client = EasyTierRemoteRPCClient(transport: transport)

    let response = try await client.patchHostname(instanceID: "11111111-2222-3333-4444-555555555555", hostname: "edge-mac")

    #expect(response == #"{"ok":true}"#)
    guard let call = await transport.firstCall() else {
        Issue.record("expected an RPC call")
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

@Test func persistHostnameBuildsRunNetworkInstancePayload() async throws {
    let transport = SpyRPCTransport(responses: [
        #"{"config":{"instance_id":"11111111-2222-3333-4444-555555555555","network_name":"office","hostname":"old-host","peer_urls":["tcp://10.0.0.1:11010"]}}"#,
        #"{"ok":true}"#,
    ])
    let client = EasyTierRemoteRPCClient(transport: transport)

    try await client.persistHostname(instanceID: "11111111-2222-3333-4444-555555555555", hostname: "new-host")
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

@Test func renameHostnameFallsBackToPatchConfigWhenPersistenceFails() async throws {
    let transport = PersistFailingRPCTransport()
    let client = EasyTierRemoteRPCClient(transport: transport)

    try await client.renameHostname(instanceID: "11111111-2222-3333-4444-555555555555", hostname: "new-host")
    let calls = await transport.allCalls()

    #expect(calls.map(\.method) == ["get_config", "run_network_instance", "patch_config"])
    let object = try rpcPayloadObject(calls[2].payload)
    let patch = object["patch"] as? [String: Any]
    #expect(patch?["hostname"] as? String == "new-host")
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
