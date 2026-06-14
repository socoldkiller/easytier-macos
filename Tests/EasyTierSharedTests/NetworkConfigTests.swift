import Foundation
import Testing
@testable import EasyTierShared

@Test func defaultNetworkConfigMatchesWebDefaults() {
    let config = NetworkConfig()

    #expect(config.dhcp)
    #expect(config.network_length == 24)
    #expect(config.network_name == "easytier")
    #expect(config.networking_method == .manual)
    #expect(config.listener_urls == ["tcp://0.0.0.0:11010", "udp://0.0.0.0:11010", "wg://0.0.0.0:11011"])
    #expect(config.vpn_portal_listen_port == 22_022)
    #expect(config.socks5_port == 1_080)
    #expect(config.bind_device == true)
    #expect(config.multi_thread == true)
}

@Test func networkConfigTracksWhetherRemotePeerConnectionIsExpected() {
    var config = NetworkConfig(networking_method: .standalone)
    #expect(!config.expectsRemotePeerConnection)

    config.networking_method = .manual
    config.peer_urls = []
    #expect(!config.expectsRemotePeerConnection)

    config.peer_urls = ["tcp://127.0.0.1:11010"]
    #expect(config.expectsRemotePeerConnection)

    config.networking_method = .publicServer
    config.public_server_url = ""
    #expect(!config.expectsRemotePeerConnection)

    config.public_server_url = "tcp://public.easytier.top:11010"
    #expect(config.expectsRemotePeerConnection)
}

@Test func tomlRoundTripsCommonConfigFields() throws {
    var config = NetworkConfig(network_name: "office", network_secret: "secret")
    config.dhcp = false
    config.virtual_ipv4 = "10.144.144.10"
    config.hostname = "macbook"
    config.peer_urls = ["tcp://example.com:11010"]
    config.proxy_cidrs = ["192.168.1.0/24"]
    config.enable_manual_routes = true
    config.routes = ["10.0.0.0/8"]
    config.disable_p2p = true
    config.enable_magic_dns = true

    let toml = NetworkConfigTOMLCodec.encode(config)
    let decoded = try NetworkConfigTOMLCodec.decode(toml)

    #expect(decoded.instance_id == config.instance_id)
    #expect(decoded.network_name == "office")
    #expect(decoded.network_secret == "secret")
    #expect(decoded.virtual_ipv4 == "10.144.144.10")
    #expect(decoded.hostname == "macbook")
    #expect(decoded.peer_urls == ["tcp://example.com:11010"])
    #expect(decoded.proxy_cidrs == ["192.168.1.0/24"])
    #expect(decoded.routes == ["10.0.0.0/8"])
    #expect(decoded.disable_p2p == true)
    #expect(decoded.enable_magic_dns == true)
}

@Test func tomlUsesCurrentEasyTierFlagNames() throws {
    var config = NetworkConfig()
    config.disable_encryption = true
    config.disable_ipv6 = true
    config.ipv6_public_addr_auto = true
    config.enable_magic_dns = true
    config.enable_private_mode = true

    let toml = NetworkConfigTOMLCodec.encode(config)

    #expect(toml.contains("enable_encryption = false"))
    #expect(toml.contains("enable_ipv6 = false"))
    #expect(toml.contains("accept_dns = true"))
    #expect(toml.contains("private_mode = true"))
    #expect(!toml.contains("disable_encryption"))
    #expect(!toml.contains("disable_ipv6"))
    #expect(!toml.contains("ipv6_public_addr_auto"))
    #expect(!toml.contains("enable_magic_dns"))
    #expect(!toml.contains("enable_private_mode"))

    let decoded = try NetworkConfigTOMLCodec.decode(toml)
    #expect(decoded.disable_encryption == true)
    #expect(decoded.disable_ipv6 == true)
    #expect(decoded.enable_magic_dns == true)
    #expect(decoded.enable_private_mode == true)
}

@Test func tomlRoundTripsPortalProxyAndPortForwardFields() throws {
    var config = NetworkConfig(network_name: "edge")
    config.enable_vpn_portal = true
    config.vpn_portal_client_network_addr = "10.14.14.0"
    config.vpn_portal_client_network_len = 24
    config.vpn_portal_listen_port = 22_121
    config.enable_socks5 = true
    config.socks5_port = 1_081
    config.port_forwards = [
        PortForwardConfig(bind_ip: "0.0.0.0", bind_port: 11_011, dst_ip: "10.144.144.2", dst_port: 80, proto: "tcp"),
    ]

    let toml = NetworkConfigTOMLCodec.encode(config)

    #expect(toml.contains("[vpn_portal_config]"))
    #expect(toml.contains("client_cidr = \"10.14.14.0/24\""))
    #expect(toml.contains("wireguard_listen = \"0.0.0.0:22121\""))
    #expect(toml.contains("socks5_proxy = \"socks5://127.0.0.1:1081\""))
    #expect(toml.contains("[[port_forward]]"))

    let decoded = try NetworkConfigTOMLCodec.decode(toml)
    #expect(decoded.enable_vpn_portal)
    #expect(decoded.vpn_portal_client_network_addr == "10.14.14.0")
    #expect(decoded.vpn_portal_client_network_len == 24)
    #expect(decoded.vpn_portal_listen_port == 22_121)
    #expect(decoded.enable_socks5 == true)
    #expect(decoded.socks5_port == 1_081)
    #expect(decoded.port_forwards.count == 1)
    #expect(decoded.port_forwards.first?.bind_ip == "0.0.0.0")
    #expect(decoded.port_forwards.first?.bind_port == 11_011)
    #expect(decoded.port_forwards.first?.dst_ip == "10.144.144.2")
    #expect(decoded.port_forwards.first?.dst_port == 80)
    #expect(decoded.port_forwards.first?.proto == "tcp")
}

@Test func tomlDecodesCurrentEasyTierPortalSchema() throws {
    let toml = """
    instance_name = "edge"
    instance_id = "11111111-1111-1111-1111-111111111111"
    dhcp = true

    [network_identity]
    network_name = "edge"
    network_secret = ""

    [vpn_portal_config]
    client_cidr = "10.14.14.0/24"
    wireguard_listen = "0.0.0.0:22121"
    """

    let decoded = try NetworkConfigTOMLCodec.decode(toml)

    #expect(decoded.enable_vpn_portal)
    #expect(decoded.vpn_portal_client_network_addr == "10.14.14.0")
    #expect(decoded.vpn_portal_client_network_len == 24)
    #expect(decoded.vpn_portal_listen_port == 22_121)
}

@Test func storagePersistsSnapshot() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let storage = EasyTierStorage(baseDirectory: directory)
    let snapshot = AppSnapshot(configs: [StoredNetworkConfig(config: NetworkConfig(network_name: "lab"))], mode: .remote(remoteRPCAddress: "tcp://127.0.0.1:15999"), lastSelectedConfigID: "abc")

    try storage.save(snapshot)
    let loaded = try storage.load()

    #expect(loaded.configs.first?.config.network_name == "lab")
    #expect(loaded.mode == .remote(remoteRPCAddress: "tcp://127.0.0.1:15999"))
    #expect(loaded.lastSelectedConfigID == "abc")
}

@MainActor
@Test func loadMigratesUnavailableServiceModeToNormalMode() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let storage = EasyTierStorage(baseDirectory: directory)
    let config = NetworkConfig(network_name: "legacy-service")
    let snapshot = AppSnapshot(
        configs: [StoredNetworkConfig(config: config)],
        mode: .service(
            configDir: directory.appendingPathComponent("config.d", isDirectory: true),
            rpcPortal: "127.0.0.1:15999",
            fileLogLevel: .off,
            fileLogDir: directory.appendingPathComponent("logs", isDirectory: true),
            configServerURL: nil
        ),
        lastSelectedConfigID: config.instance_id
    )
    try storage.save(snapshot)

    let store = EasyTierAppStore(client: UnavailableEasyTierCoreClient(reason: "test"), storage: storage)

    await store.load()
    store.stopPolling()

    #expect(store.mode == .default)
    #expect(store.selectedConfigID == config.instance_id)
    #expect(store.logLines.contains { $0.contains("Service mode is not available") })
}

@MainActor
@Test func applyModeDoesNotPersistUnavailableServiceMode() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let storage = EasyTierStorage(baseDirectory: directory)
    let store = EasyTierAppStore(client: UnavailableEasyTierCoreClient(reason: "test"), storage: storage)
    let serviceMode = AppMode.service(
        configDir: directory.appendingPathComponent("config.d", isDirectory: true),
        rpcPortal: "127.0.0.1:15999",
        fileLogLevel: .off,
        fileLogDir: directory.appendingPathComponent("logs", isDirectory: true),
        configServerURL: nil
    )

    await store.applyMode(serviceMode)

    let snapshot = try storage.load()
    #expect(store.mode == .default)
    #expect(snapshot.mode == .default)
}

@MainActor
@Test func selectedRunningInstanceDoesNotFallBackToFirstInstance() {
    let first = NetworkConfig(instance_id: "first-id", network_name: "first-network")
    let second = NetworkConfig(instance_id: "second-id", network_name: "second-network")
    let store = EasyTierAppStore(client: UnavailableEasyTierCoreClient(reason: "test"))

    store.configs = [StoredNetworkConfig(config: first), StoredNetworkConfig(config: second)]
    store.selectedConfigID = second.instance_id
    store.instances = [NetworkInstance(instance_id: first.instance_id, name: first.network_name, running: true)]

    #expect(store.selectedRunningInstance == nil)
    #expect(store.selectedMemberStatuses.isEmpty)
}

@MainActor
@Test func selectedRunningInstancePrefersInstanceIDWhenNamesMatch() throws {
    let first = NetworkConfig(instance_id: "first-id", network_name: "shared-network")
    let second = NetworkConfig(instance_id: "second-id", network_name: "shared-network")
    let store = EasyTierAppStore(client: UnavailableEasyTierCoreClient(reason: "test"))

    store.configs = [StoredNetworkConfig(config: first), StoredNetworkConfig(config: second)]
    store.selectedConfigID = second.instance_id
    store.instances = [
        NetworkInstance(instance_id: first.instance_id, name: first.network_name, running: true),
        NetworkInstance(instance_id: second.instance_id, name: second.network_name, running: true),
    ]

    let selected = try #require(store.selectedRunningInstance)
    #expect(selected.instance_id == second.instance_id)
}

@Test func unavailableClientReportsClearRuntimeFailure() async {
    let client = UnavailableEasyTierCoreClient(reason: "missing dylib")

    do {
        try await client.validate(toml: "")
        Issue.record("validate should fail when FFI is unavailable")
    } catch let error as EasyTierCoreError {
        #expect(error == .ffiUnavailable("missing dylib"))
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test func permissionStateRawValuesAreStable() {
    #expect(PermissionState.notRegistered.rawValue == "notRegistered")
    #expect(PermissionState.requiresApproval.rawValue == "requiresApproval")
    #expect(PermissionState.enabled.rawValue == "enabled")
    #expect(PermissionState.notFound.rawValue == "notFound")
    #expect(PermissionState.error.rawValue == "error")
}

@Test func privilegedHelperUnavailableErrorIsActionable() {
    let message = PrivilegedHelperError.unavailable.localizedDescription
    #expect(message.contains("privileged helper"))
    #expect(message.contains("TUN"))
}

@Test func privilegedHelperErrorPayloadRoundTripsAndFeedsLocalizedDescription() {
    let payload = PrivilegedHelperErrorPayload(
        code: "runFailed",
        message: "TUN device creation failed.",
        recoverySuggestion: "Reinstall the privileged helper."
    )

    let decoded = PrivilegedHelperErrorPayload.decode(from: payload.encodedString())
    let message = PrivilegedHelperError.helperReported(decoded).localizedDescription

    #expect(decoded == payload)
    #expect(message.contains("TUN device creation failed."))
    #expect(message.contains("Reinstall the privileged helper."))
}

@MainActor
@Test func runSelectedConfigKeepsPendingInstanceWhenRuntimeListIsInitiallyEmpty() async throws {
    let client = PendingStartClient()
    let config = NetworkConfig(instance_id: "pending-id", network_name: "pending-network")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = EasyTierAppStore(client: client, storage: EasyTierStorage(baseDirectory: directory))

    store.configs = [StoredNetworkConfig(config: config)]
    store.selectedConfigID = config.instance_id

    await store.runSelectedConfig()

    let selected = try #require(store.selectedRunningInstance)
    #expect(client.didRun)
    #expect(selected.instance_id == config.instance_id)
    #expect(selected.name == config.network_name)
    #expect(selected.running)
    #expect(selected.detail?.running == true)
    #expect(store.lastError == nil)
}

@MainActor
@Test func helperPermissionErrorsDoNotBecomeModalLastError() async throws {
    let client = HelperRequiresApprovalClient()
    let config = NetworkConfig(instance_id: "approval-id", network_name: "approval-network")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = EasyTierAppStore(client: client, storage: EasyTierStorage(baseDirectory: directory))

    store.configs = [StoredNetworkConfig(config: config)]
    store.selectedConfigID = config.instance_id

    await store.runSelectedConfig()

    #expect(store.lastError == nil)
    #expect(store.logLines.contains { $0.contains("Privileged helper needs user approval") })
}

@Test func runtimeInfoDerivesLocalAndPeerMembers() throws {
    let json = """
    {
      "dev_name": "utun8",
      "my_node_info": {
        "virtual_ipv4": { "address": { "addr": 168427521 }, "network_length": 24 },
        "hostname": "macbook",
        "version": "2.4.0",
        "peer_id": 100,
        "stun_info": { "udp_nat_type": 1, "tcp_nat_type": 0, "last_update_time": 0 }
      },
      "peer_route_pairs": [
        {
          "route": {
            "peer_id": 200,
            "ipv4_addr": "10.10.0.2/24",
            "next_hop_peer_id": 200,
            "cost": 1,
            "hostname": "office-mini",
            "stun_info": { "udp_nat_type": 6, "tcp_nat_type": 0, "last_update_time": 0 },
            "version": "2.4.0"
          },
          "peer": {
            "peer_id": 200,
            "conns": [
              {
                "conn_id": "c1",
                "my_peer_id": 100,
                "is_client": true,
                "peer_id": 200,
                "features": [],
                "tunnel": { "tunnel_type": "tcp", "local_addr": { "url": "tcp://127.0.0.1:11010" }, "remote_addr": { "url": "tcp://example.com:11010" } },
                "stats": { "rx_bytes": 4096, "tx_bytes": 2048, "rx_packets": 4, "tx_packets": 2, "latency_us": 1500 },
                "loss_rate": 0.25
              }
            ]
          }
        }
      ],
      "running": true
    }
    """

    let info = try JSONDecoder().decode(NetworkInstanceRunningInfo.self, from: Data(json.utf8))
    let members = info.memberStatuses

    #expect(members.count == 2)
    #expect(members[0].isLocal)
    #expect(members[0].hostname == "macbook")
    #expect(members[0].virtualIPv4 == "10.10.0.1/24")
    #expect(members[0].natType == "Open Internet")

    #expect(!members[1].isLocal)
    #expect(members[1].peerID == "200")
    #expect(members[1].virtualIPv4 == "10.10.0.2/24")
    #expect(members[1].routeCost == "P2P")
    #expect(members[1].tunnelProto == "tcp")
    #expect(members[1].latency == "2 ms")
    #expect(members[1].uploadTotal == "2.0 KiB")
    #expect(members[1].downloadTotal == "4.0 KiB")
    #expect(members[1].lossRate == "25%")
    #expect(members[1].natType == "Symmetric")
}

@Test func runtimeInfoReportsLocalOnlyNodeAsFullyConnected() throws {
    let json = """
    {
      "my_node_info": {
        "hostname": "macbook",
        "peer_id": 100
      },
      "running": true
    }
    """

    let info = try JSONDecoder().decode(NetworkInstanceRunningInfo.self, from: Data(json.utf8))
    let instance = NetworkInstance(instance_id: "local", name: "local", running: true, detail: info)

    #expect(info.isFullyConnected)
    #expect(instance.isFullyConnected)
    #expect(!info.isFullyConnected(expectRemotePeers: true))
    #expect(!instance.isFullyConnected(expectRemotePeers: true))
}

@Test func runtimeInfoWaitsUntilRemotePeerRoutesHaveConnections() throws {
    let waitingJSON = """
    {
      "my_node_info": {
        "hostname": "macbook",
        "peer_id": 100
      },
      "peer_route_pairs": [
        {
          "route": { "peer_id": 200, "hostname": "office-mini", "cost": 1 },
          "peer": { "peer_id": 200, "conns": [] }
        }
      ],
      "running": true
    }
    """
    let connectedJSON = """
    {
      "my_node_info": {
        "hostname": "macbook",
        "peer_id": 100
      },
      "peer_route_pairs": [
        {
          "route": { "peer_id": 200, "hostname": "office-mini", "cost": 1 },
          "peer": { "peer_id": 200, "conns": [ { "conn_id": "c1" } ] }
        }
      ],
      "running": true
    }
    """

    let waiting = try JSONDecoder().decode(NetworkInstanceRunningInfo.self, from: Data(waitingJSON.utf8))
    let connected = try JSONDecoder().decode(NetworkInstanceRunningInfo.self, from: Data(connectedJSON.utf8))

    #expect(!waiting.isFullyConnected)
    #expect(!waiting.isFullyConnected(expectRemotePeers: true))
    #expect(connected.isFullyConnected)
    #expect(connected.isFullyConnected(expectRemotePeers: true))
}

@Test func runtimeInfoReadsCurrentApiMemberFields() throws {
    let json = """
    {
      "my_node_info": {
        "ipv4_addr": "10.10.0.1/24",
        "hostname": "public-node",
        "peer_id": 100,
        "feature_flag": { "is_public_server": true }
      },
      "peer_route_pairs": [
        {
          "route": {
            "peer_id": 200,
            "ipv4_addr": "10.10.0.2/24",
            "hostname": "remote-public",
            "stun_info": { "udp_nat_type": 3 },
            "feature_flag": { "is_public_server": true }
          },
          "peer": {
            "peer_id": 200,
            "default_conn_id": "preferred",
            "conns": [
              { "conn_id": "backup", "loss_rate": 0.8 },
              { "conn_id": "preferred", "loss_rate": 0.125 }
            ]
          }
        }
      ]
    }
    """

    let info = try JSONDecoder().decode(NetworkInstanceRunningInfo.self, from: Data(json.utf8))
    let members = info.memberStatuses

    #expect(members[0].virtualIPv4 == "10.10.0.1/24")
    #expect(members[0].isPublicServer)
    #expect(members[1].lossRate == "93%")
    #expect(members[1].natType == "Full Cone")
    #expect(members[1].isPublicServer)
}

@Test func runtimeInfoAcceptsProtobufJsonFieldNames() throws {
    let json = """
    {
      "peer_route_pairs": [
        {
          "route": {
            "peerId": 200,
            "ipv4Addr": "10.10.0.2/24",
            "hostname": "PublicServer_demo",
            "stunInfo": { "udpNatType": "Symmetric" }
          },
          "peer": {
            "peerId": 200,
            "conns": [
              { "connId": "a", "lossRate": 0.2 },
              { "connId": "b", "lossRate": 0.1 }
            ]
          }
        }
      ]
    }
    """

    let info = try JSONDecoder().decode(NetworkInstanceRunningInfo.self, from: Data(json.utf8))
    let member = try #require(info.memberStatuses.first)

    #expect(member.peerID == "200")
    #expect(member.lossRate == "30%")
    #expect(member.natType == "Symmetric")
    #expect(member.isPublicServer)
}

@Test func runtimeInfoAcceptsUppercaseNatEnumNames() throws {
    let json = """
    {
      "peer_route_pairs": [
        {
          "route": {
            "peer_id": 200,
            "hostname": "remote",
            "stun_info": { "udp_nat_type": "PORT_RESTRICTED" }
          },
          "peer": { "peer_id": 200, "conns": [] }
        }
      ]
    }
    """

    let info = try JSONDecoder().decode(NetworkInstanceRunningInfo.self, from: Data(json.utf8))
    let member = try #require(info.memberStatuses.first)

    #expect(member.natType == "Port Restricted")
}

@Test func runtimeInfoTotalsTrafficFromPeerRoutePairs() throws {
    let json = """
    {
      "peer_route_pairs": [
        { "peer": { "peer_id": 1, "conns": [ { "stats": { "rx_bytes": "100", "tx_bytes": "200", "latency_us": "900" } } ] } },
        { "peer": { "peer_id": 2, "conns": [ { "stats": { "rx_bytes": 300, "tx_bytes": 400 } } ] } }
      ]
    }
    """

    let info = try JSONDecoder().decode(NetworkInstanceRunningInfo.self, from: Data(json.utf8))
    let totals = info.trafficTotals

    #expect(totals.txBytes == 600)
    #expect(totals.rxBytes == 400)
    #expect(info.peer_route_pairs?.first?.peer?.conns?.first?.stats?.latency_us == 900)
}

@Test func runtimeInfoKeepsMembersWhenOneConnectionHasUnexpectedShape() throws {
    let json = """
    {
      "my_node_info": { "hostname": "macbook", "version": "2.4.0", "peer_id": 100 },
      "peer_route_pairs": [
        {
          "route": { "peer_id": 200, "hostname": "office-mini", "cost": 2, "version": "2.4.0" },
          "peer": {
            "peer_id": 200,
            "conns": [
              { "stats": { "rx_bytes": { "unexpected": true }, "tx_bytes": "1024" } },
              { "stats": { "rx_bytes": "2048", "tx_bytes": "4096" }, "loss_rate": "0.1" }
            ]
          }
        }
      ]
    }
    """

    let info = try JSONDecoder().decode(NetworkInstanceRunningInfo.self, from: Data(json.utf8))
    let members = info.memberStatuses

    #expect(members.count == 2)
    #expect(members[1].hostname == "office-mini")
    #expect(members[1].uploadTotal == "5.0 KiB")
    #expect(members[1].downloadTotal == "2.0 KiB")
    #expect(members[1].lossRate == "10%")
}

@Test func workspaceTabsExposeTrafficView() {
    #expect(WorkspaceTab.allCases.map(\.rawValue) == ["Status", "View", "Config", "Logs"])
}

private final class PendingStartClient: EasyTierCoreClient, @unchecked Sendable {
    var didRun = false

    func version() async throws -> String { "test" }
    func validate(toml _: String) async throws {}

    func run(config _: NetworkConfig) async throws {
        didRun = true
    }

    func stop(instanceNames _: [String]) async throws {}
    func retain(instanceNames _: [String]) async throws {}
    func listInstances() async throws -> [NetworkInstance] { [] }
    func collectNetworkInfos() async throws -> [String: NetworkInstanceRunningInfo] { [:] }

    func callJSONRPC(service _: String, method _: String, domain _: String?, payload _: String) async throws -> String {
        throw EasyTierCoreError.operationFailed("unsupported")
    }

    func startConfigServerClient(url _: URL) async throws {
        throw EasyTierCoreError.operationFailed("unsupported")
    }

    func stopConfigServerClient() async throws {}
    func isConfigServerClientConnected() async throws -> Bool { false }
}

private final class HelperRequiresApprovalClient: EasyTierCoreClient, @unchecked Sendable {
    func version() async throws -> String { "test" }
    func validate(toml _: String) async throws {}

    func run(config _: NetworkConfig) async throws {
        throw PrivilegedHelperError.helperReported(
            PrivilegedHelperErrorPayload(
                code: "helperRequiresApproval",
                message: "Privileged helper is installed but macOS has not allowed it to run in the background.",
                recoverySuggestion: "Open System Settings > General > Login Items & Extensions, allow EasyTier, then return to EasyTier and try again."
            )
        )
    }

    func stop(instanceNames _: [String]) async throws {}
    func retain(instanceNames _: [String]) async throws {}
    func listInstances() async throws -> [NetworkInstance] { [] }
    func collectNetworkInfos() async throws -> [String: NetworkInstanceRunningInfo] { [:] }
    func callJSONRPC(service _: String, method _: String, domain _: String?, payload _: String) async throws -> String { "" }
    func startConfigServerClient(url _: URL) async throws {}
    func stopConfigServerClient() async throws {}
    func isConfigServerClientConnected() async throws -> Bool { false }
}
