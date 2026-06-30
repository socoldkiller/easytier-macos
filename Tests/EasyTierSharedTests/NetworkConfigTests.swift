import Foundation
import ServiceManagement
import Testing
@testable import EasyTierShared

@Test func searchQueryMatchesAcrossCaseAndSeparators() {
    let fields = ["ctwdeMac-mini.local", "Office Mac mini", "Peer 1428946557"]

    #expect(SearchQuery("office mac").matches(fields))
    #expect(SearchQuery("CTWDEMACMINI").matches(fields))
    #expect(SearchQuery("peer:1428946557").matches(fields))
    #expect(!SearchQuery("office linux").matches(fields))
}

@Test func searchQueryRequiresEveryToken() {
    let fields = ["backend-dev", "10.126.126.7", "public server"]

    #expect(SearchQuery("backend 10.126").matches(fields))
    #expect(SearchQuery("backenddev public").matches(fields))
    #expect(!SearchQuery("backend singapore").matches(fields))
}

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

@Test func defaultConfigUsesBasicMode() {
    let config = NetworkConfig()

    #expect(config.advanced_settings == false)
    #expect(config.peer_urls == [])
    #expect(config.network_secret == "")
}

@Test func togglingAdvancedSettingsPreservesBasicFields() {
    var config = NetworkConfig(network_name: "office", network_secret: "secret")
    config.peer_urls = ["tcp://example.com:11010"]
    config.advanced_settings = true
    config.advanced_settings = false

    #expect(config.network_name == "office")
    #expect(config.network_secret == "secret")
    #expect(config.peer_urls == ["tcp://example.com:11010"])
}

@Test func listenerURLDefaultsSuggestNextMissingProtocol() {
    #expect(ListenerURLDefaults.next(excluding: NetworkConfig().listener_urls) == "ws://0.0.0.0:11011")
    #expect(ListenerURLDefaults.next(excluding: [" TCP://0.0.0.0:11010 "]) == "udp://0.0.0.0:11010")
    #expect(ListenerURLDefaults.next(excluding: ListenerURLDefaults.addSuggestions) == "")
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

@Test func hostProxyCIDRUsesPrimaryHostRouteNetwork() {
    let interfaces: [(name: String, address: UInt32, netmask: UInt32)] = [
        ("en1", 0x0a00_022a, 0xff00_0000),
        ("en0", 0xc0a8_012a, 0xffff_ff00),
    ]

    #expect(HostProxyCIDR.cidrs(from: interfaces, primaryInterface: "en0") == ["192.168.1.0/24", "10.0.0.0/8"])
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

    let toml = try NetworkConfigTOMLCodec.encode(config)
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

@MainActor
@Test func importTOMLGeneratesNewInstanceIDWhenImportedIDAlreadyExists() throws {
    let config = NetworkConfig(instance_id: "duplicate-id", network_name: "office")
    let store = EasyTierAppStore()
    store.configs = [StoredNetworkConfig(config: config)]

    store.importTOML(try NetworkConfigTOMLCodec.encode(config))

    #expect(store.configs.count == 2)
    #expect(Set(store.configs.map(\.id)).count == 2)
    #expect(store.selectedConfigID != "duplicate-id")
}

@Test func tomlUsesCurrentEasyTierFlagNames() throws {
    var config = NetworkConfig()
    config.disable_encryption = true
    config.disable_ipv6 = true
    config.ipv6_public_addr_auto = true
    config.enable_magic_dns = true
    config.enable_private_mode = true

    let toml = try NetworkConfigTOMLCodec.encode(config)

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

    let toml = try NetworkConfigTOMLCodec.encode(config)

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

@Test func tomlRejectsMalformedPortForwardInsteadOfDroppingIt() {
    let toml = """
    instance_name = "edge"

    [[port_forward]]
    bind_addr = "0.0.0.0"
    dst_addr = "10.144.144.2:80"
    proto = "tcp"
    """

    do {
        _ = try NetworkConfigTOMLCodec.decode(toml)
        Issue.record("malformed port_forward should not be dropped silently")
    } catch TOMLCodecError.invalidValue(let message) {
        #expect(message.contains("port_forward #1"))
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test func tomlRejectsMalformedIPv4InsteadOfDefaultingIt() {
    let toml = """
    instance_name = "edge"
    ipv4 = "/24"
    """

    do {
        _ = try NetworkConfigTOMLCodec.decode(toml)
        Issue.record("malformed ipv4 should not be accepted")
    } catch TOMLCodecError.invalidValue(let message) {
        #expect(message.contains("ipv4"))
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test func validatorAllowsSamePortOnDifferentTransports() throws {
    var config = NetworkConfig(network_name: "edge")
    config.listener_urls = ["tcp://0.0.0.0:11010", "udp://0.0.0.0:11010"]

    try NetworkConfigValidator.validate(config)
}

@Test func validatorReportsConflictingActiveConfigPorts() throws {
    var running = NetworkConfig(instance_id: "running-id", network_name: "running")
    running.listener_urls = ["tcp://0.0.0.0:11010"]

    var selected = NetworkConfig(instance_id: "selected-id", network_name: "selected")
    selected.listener_urls = ["tcp://127.0.0.1:11010"]

    try NetworkConfigValidator.validate(selected, activeConfigs: [running])
}

@Test func validatorReportsConflictingPortForwardAndListener() throws {
    var config = NetworkConfig(instance_id: "edge-id", network_name: "edge")
    config.listener_urls = ["tcp://0.0.0.0:11010"]
    config.port_forwards = [
        PortForwardConfig(bind_ip: "0.0.0.0", bind_port: 11_010, dst_ip: "10.144.144.2", dst_port: 80, proto: "tcp"),
    ]

    try NetworkConfigValidator.validate(config)
}

@Test func stateJsonStoresTomlReferenceAndConfigLivesInToml() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let storage = EasyTierStorage(baseDirectory: directory)
    var config = NetworkConfig(instance_id: "lab-id", network_name: "lab", network_secret: "secret")
    config.port_forwards = [
        PortForwardConfig(bind_ip: "127.0.0.1", bind_port: 8_080, dst_ip: "10.144.144.2", dst_port: 80, proto: "tcp"),
    ]
    let snapshot = AppSnapshot(
        configs: [StoredNetworkConfig(config: config)],
        mode: .remote(remoteRPCAddress: "tcp://127.0.0.1:15999"),
        lastSelectedConfigID: "abc"
    )

    try storage.save(snapshot)

    let state = try String(contentsOf: directory.appendingPathComponent("state.json"), encoding: .utf8)
    let tomlURL = directory.appendingPathComponent("configs/lab-id.toml")
    let toml = try String(contentsOf: tomlURL, encoding: .utf8)
    let stateObject = try #require(JSONSerialization.jsonObject(with: Data(state.utf8)) as? [String: Any])
    let stateConfigs = try #require(stateObject["configs"] as? [[String: Any]])

    #expect(stateConfigs.first?["tomlPath"] as? String == "configs/lab-id.toml")
    #expect(!state.contains("network_name"))
    #expect(!state.contains("network_secret"))
    #expect(!state.contains("port_forwards"))
    #expect(FileManager.default.fileExists(atPath: tomlURL.path))
    #expect(toml.contains("network_name = \"lab\""))

    let loaded = try storage.load()

    #expect(loaded.configs.first?.config.network_name == "lab")
    #expect(loaded.mode == .remote(remoteRPCAddress: "tcp://127.0.0.1:15999"))
    #expect(loaded.lastSelectedConfigID == "abc")
}

@MainActor
@Test func appStoreSavesNetworkSecretInKeychainNotToml() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let storage = EasyTierStorage(baseDirectory: directory)
    let secrets = MemoryNetworkSecretStore()
    let config = NetworkConfig(instance_id: "secret-id", network_name: "lab", network_secret: "super-secret")
    let store = EasyTierAppStore(
        client: UnavailableEasyTierCoreClient(reason: "test"),
        storage: storage,
        networkSecretStore: secrets
    )

    store.configs = [StoredNetworkConfig(config: config)]
    store.selectedConfigID = config.instance_id
    store.save()

    let toml = try String(contentsOf: directory.appendingPathComponent("configs/secret-id.toml"), encoding: .utf8)

    #expect(secrets.secrets["lab"] == "super-secret")
    #expect(!toml.contains("super-secret"))
    #expect(store.configs.first?.config.network_secret?.nilIfEmpty == nil)
}

@MainActor
@Test func runSelectedConfigUsesKeychainNetworkSecret() async throws {
    let client = RecordingToggleClient()
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "run-secret"])
    let config = NetworkConfig(instance_id: "run-id", network_name: "office", network_secret: nil)
    let store = EasyTierAppStore(client: client, networkSecretStore: secrets)

    store.configs = [StoredNetworkConfig(config: config)]
    store.selectedConfigID = config.instance_id

    await store.runSelectedConfig()

    #expect(client.runConfigs.first?.network_secret == "run-secret")
}

@MainActor
@Test func longSystemSleepRestartsPreviouslyRunningConfig() async throws {
    let client = RecordingToggleClient()
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "wake-secret"])
    let config = NetworkConfig(instance_id: "wake-id", network_name: "office", network_secret: nil)
    let store = EasyTierAppStore(client: client, networkSecretStore: secrets)

    store.configs = [StoredNetworkConfig(config: config)]
    store.selectedConfigID = config.instance_id
    store.instances = [NetworkInstance(instance_id: config.instance_id, name: config.network_name, running: true)]
    client.networkInfos = [
        config.network_name: NetworkInstanceRunningInfo(running: true, instance_id: config.instance_id),
    ]

    store.handleSystemWillSleep(now: Date(timeIntervalSince1970: 100))
    await store.handleSystemDidWake(now: Date(timeIntervalSince1970: 160))

    #expect(client.stoppedInstanceNames == [[config.network_name]])
    #expect(client.runConfigs.map(\.instance_id) == [config.instance_id])
    #expect(client.runConfigs.first?.network_secret == "wake-secret")
}

@MainActor
@Test func shortSystemSleepOnlyRefreshesRuntime() async throws {
    let client = RecordingToggleClient()
    let config = NetworkConfig(instance_id: "short-wake-id", network_name: "office")
    let store = EasyTierAppStore(client: client)

    store.configs = [StoredNetworkConfig(config: config)]
    store.selectedConfigID = config.instance_id
    store.instances = [NetworkInstance(instance_id: config.instance_id, name: config.network_name, running: true)]
    client.networkInfos = [
        config.network_name: NetworkInstanceRunningInfo(running: true, instance_id: config.instance_id),
    ]

    store.handleSystemWillSleep(now: Date(timeIntervalSince1970: 100))
    await store.handleSystemDidWake(now: Date(timeIntervalSince1970: 110))

    #expect(client.stoppedInstanceNames.isEmpty)
    #expect(client.runConfigs.isEmpty)
    #expect(store.instances.first?.instance_id == config.instance_id)
}

@MainActor
@Test func runningRuntimePreventsIdleSystemSleep() async {
    let client = RecordingToggleClient()
    let sleepPreventer = RecordingSystemSleepPreventer()
    let config = NetworkConfig(instance_id: "awake-id", network_name: "office")
    let store = EasyTierAppStore(client: client, systemSleepPreventer: sleepPreventer)
    client.networkInfos = [
        config.network_name: NetworkInstanceRunningInfo(running: true, instance_id: config.instance_id),
    ]

    await store.refreshRuntime()

    #expect(sleepPreventer.isPreventingSystemSleep)
    #expect(sleepPreventer.calls.last?.prevented == true)
}

@MainActor
@Test func idleSystemSleepAssertionIsReleasedWhenRuntimeStops() async {
    let client = RecordingToggleClient()
    let sleepPreventer = RecordingSystemSleepPreventer()
    let config = NetworkConfig(instance_id: "awake-release-id", network_name: "office")
    let store = EasyTierAppStore(client: client, systemSleepPreventer: sleepPreventer)
    client.networkInfos = [
        config.network_name: NetworkInstanceRunningInfo(running: true, instance_id: config.instance_id),
    ]
    await store.refreshRuntime()

    client.networkInfos = [:]
    await store.refreshRuntime()

    #expect(!sleepPreventer.isPreventingSystemSleep)
    #expect(sleepPreventer.calls.map(\.prevented) == [true, false])
}

@MainActor
@Test func exportSelectedTOMLUsesKeychainNetworkSecret() async throws {
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "export-secret"])
    let config = NetworkConfig(instance_id: "export-id", network_name: "office", network_secret: nil)
    let store = EasyTierAppStore(
        client: UnavailableEasyTierCoreClient(reason: "test"),
        networkSecretStore: secrets
    )

    store.configs = [StoredNetworkConfig(config: config)]
    store.selectedConfigID = config.instance_id

    let toml = try await store.exportSelectedTOML()

    #expect(toml.contains("export-secret"))
}

@MainActor
@Test func networkSecretAutofillRequiresSavedSecretAndBiometrics() async {
    let config = NetworkConfig(instance_id: "autofill-id", network_name: "office")
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "secret"], canAutofill: true)
    let store = EasyTierAppStore(
        client: UnavailableEasyTierCoreClient(reason: "test"),
        networkSecretStore: secrets
    )

    #expect(await store.networkSecretCanAutofill(for: config))

    secrets.canAutofill = false

    #expect(!(await store.networkSecretCanAutofill(for: config)))
    #expect(secrets.readReasons.isEmpty)
}

@MainActor
@Test func networkSecretAutofillSilentlyIgnoresReadErrors() async {
    let config = NetworkConfig(instance_id: "autofill-error-id", network_name: "office")
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "secret"], canAutofill: true)
    secrets.readError = EasyTierCoreError.operationFailed("user canceled")
    let store = EasyTierAppStore(
        client: UnavailableEasyTierCoreClient(reason: "test"),
        networkSecretStore: secrets
    )

    let secret = await store.autofillNetworkSecret(for: config)

    #expect(secret == nil)
    #expect(store.lastError == nil)
    #expect(secrets.readReasons.count == 1)
}

@MainActor
@Test func explicitNetworkSecretReadReportsErrors() async {
    let config = NetworkConfig(instance_id: "explicit-error-id", network_name: "office")
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "secret"], canAutofill: true)
    secrets.readError = EasyTierCoreError.operationFailed("keychain failed")
    let store = EasyTierAppStore(
        client: UnavailableEasyTierCoreClient(reason: "test"),
        networkSecretStore: secrets
    )

    do {
        _ = try await store.revealNetworkSecret(for: config)
        Issue.record("explicit read should throw")
    } catch {
        #expect(error.localizedDescription.contains("keychain failed"))
    }
}

@MainActor
@Test func secretCacheAvoidsRepeatedKeychainReads() async {
    let config = NetworkConfig(instance_id: "cache-id", network_name: "office")
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "cached-secret"], canAutofill: true)
    let store = EasyTierAppStore(
        client: UnavailableEasyTierCoreClient(reason: "test"),
        networkSecretStore: secrets
    )

    _ = try? await store.revealNetworkSecret(for: config)
    #expect(secrets.readReasons.count == 1)

    _ = try? await store.revealNetworkSecret(for: config)
    #expect(secrets.readReasons.count == 1, "second read should hit the in-memory cache")
}

@MainActor
@Test func importTOMLMigratesNetworkSecretToKeychain() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let storage = EasyTierStorage(baseDirectory: directory)
    let secrets = MemoryNetworkSecretStore()
    let config = NetworkConfig(instance_id: "import-id", network_name: "office", network_secret: "import-secret")
    let store = EasyTierAppStore(
        client: UnavailableEasyTierCoreClient(reason: "test"),
        storage: storage,
        networkSecretStore: secrets
    )

    store.importTOML(try NetworkConfigTOMLCodec.encode(config))

    let toml = try String(contentsOf: directory.appendingPathComponent("configs/import-id.toml"), encoding: .utf8)

    #expect(secrets.secrets["office"] == "import-secret")
    #expect(!toml.contains("import-secret"))
    #expect(store.configs.first?.config.network_secret?.nilIfEmpty == nil)
}

@MainActor
@Test func deleteSelectedConfigKeepsKeychainNetworkSecret() async {
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "secret"])
    let config = NetworkConfig(instance_id: "delete-id", network_name: "office")
    let store = EasyTierAppStore(client: RecordingToggleClient(), networkSecretStore: secrets)

    store.configs = [StoredNetworkConfig(config: config)]
    store.selectedConfigID = config.instance_id

    await store.deleteSelectedConfig()

    #expect(secrets.secrets["office"] == "secret")
}

@MainActor
@Test func keychainNetworkSecretsAreScopedByNetworkName() {
    let secrets = MemoryNetworkSecretStore()
    let first = NetworkConfig(instance_id: "first-id", network_name: "office", network_secret: "office-secret")
    let second = NetworkConfig(instance_id: "second-id", network_name: "lab", network_secret: "lab-secret")
    let store = EasyTierAppStore(
        client: UnavailableEasyTierCoreClient(reason: "test"),
        networkSecretStore: secrets
    )

    store.configs = [StoredNetworkConfig(config: first), StoredNetworkConfig(config: second)]
    store.save()

    #expect(secrets.secrets["office"] == "office-secret")
    #expect(secrets.secrets["lab"] == "lab-secret")
}

@MainActor
@Test func updateConfigMigratesKeychainSecretWhenNetworkNameChanges() {
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "office-secret"])
    let original = NetworkConfig(instance_id: "rename-id", network_name: "office")
    let store = EasyTierAppStore(
        client: UnavailableEasyTierCoreClient(reason: "test"),
        networkSecretStore: secrets
    )

    store.configs = [StoredNetworkConfig(config: original)]
    store.selectedConfigID = original.instance_id

    var updated = original
    updated.network_name = "renamed"
    store.updateConfig(id: original.instance_id, with: updated, saveImmediately: true)

    #expect(secrets.secrets["renamed"] == "office-secret")
    #expect(secrets.secrets["office"] == nil)
}

@Test func stateJsonWithoutRuntimeIntentsDefaultsToEmptyIntentList() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let storage = EasyTierStorage(baseDirectory: directory)
    let config = NetworkConfig(instance_id: "legacy-id", network_name: "legacy")
    let configURL = directory.appendingPathComponent("configs/legacy-id.toml")
    try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try NetworkConfigTOMLCodec.encode(config).write(to: configURL, atomically: true, encoding: .utf8)
    let state = """
    {
      "configs" : [
        {
          "id" : "legacy-id",
          "source" : "user",
          "tomlPath" : "configs/legacy-id.toml"
        }
      ],
      "lastSelectedConfigID" : "legacy-id"
    }
    """
    try state.write(to: directory.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)

    let loaded = try storage.load()

    #expect(loaded.runtimeIntents.isEmpty)
    #expect(loaded.configs.first?.config.network_name == "legacy")
}

@Test func runtimeIntentsRoundTripThroughStateJson() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let storage = EasyTierStorage(baseDirectory: directory)
    let config = NetworkConfig(instance_id: "lab-id", network_name: "lab")
    let intent = RuntimeIntent(
        target: RuntimeIntentTarget(
            networkName: "lab",
            instanceID: "remote-id",
            peerID: "200",
            recentHostname: "old-host",
            recentIPv4: "10.126.126.8",
            isLocal: false
        ),
        kind: .hostname,
        desired: RuntimeIntentDesired(hostname: "new-host"),
        base: RuntimeIntentBase(hostname: "old-host"),
        status: .pending
    )
    let snapshot = AppSnapshot(
        configs: [StoredNetworkConfig(config: config)],
        mode: .default,
        lastSelectedConfigID: config.instance_id,
        runtimeIntents: [intent]
    )

    try storage.save(snapshot)
    let loaded = try storage.load()

    #expect(loaded.runtimeIntents.count == 1)
    #expect(loaded.runtimeIntents.first?.target.instanceID == "remote-id")
    #expect(loaded.runtimeIntents.first?.desired.hostname == "new-host")
    #expect(loaded.runtimeIntents.first?.base.hostname == "old-host")
    #expect(loaded.runtimeIntents.first?.status == .pending)
}

@Test func defaultStorageUsesBundleSpecificAppSupportDirectory() {
    #expect(EasyTierStorage.default.baseDirectory.lastPathComponent == "com.kkrainbow.easytier.mac")
}

@MainActor
@Test func selectedConfigDoesNotFallBackToFirstConfigWhenSelectionIsCleared() {
    let first = NetworkConfig(instance_id: "first-id", network_name: "first-network")
    let second = NetworkConfig(instance_id: "second-id", network_name: "second-network")
    let store = EasyTierAppStore(client: UnavailableEasyTierCoreClient(reason: "test"))

    store.configs = [StoredNetworkConfig(config: first), StoredNetworkConfig(config: second)]
    store.selectedConfigID = nil
    store.instances = [NetworkInstance(instance_id: first.instance_id, name: first.network_name, running: true)]

    #expect(store.selectedConfig == nil)
    #expect(store.selectedRunningInstance == nil)
    #expect(!store.selectedConfigIsRunning)
}

@MainActor
@Test func selectNextConfigCyclesThroughConfigsAndPersistsSelection() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let storage = EasyTierStorage(baseDirectory: directory)
    let first = NetworkConfig(instance_id: "first-id", network_name: "first-network")
    let second = NetworkConfig(instance_id: "second-id", network_name: "second-network")
    let store = EasyTierAppStore(client: UnavailableEasyTierCoreClient(reason: "test"), storage: storage)

    store.configs = [StoredNetworkConfig(config: first), StoredNetworkConfig(config: second)]
    store.selectedConfigID = first.instance_id

    store.selectNextConfig()

    #expect(store.selectedConfigID == second.instance_id)
    #expect(try storage.load().lastSelectedConfigID == second.instance_id)

    store.selectNextConfig()

    #expect(store.selectedConfigID == first.instance_id)
}

@MainActor
@Test func selectPreviousConfigWrapsToLastConfig() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let storage = EasyTierStorage(baseDirectory: directory)
    let first = NetworkConfig(instance_id: "first-id", network_name: "first-network")
    let second = NetworkConfig(instance_id: "second-id", network_name: "second-network")
    let store = EasyTierAppStore(client: UnavailableEasyTierCoreClient(reason: "test"), storage: storage)

    store.configs = [StoredNetworkConfig(config: first), StoredNetworkConfig(config: second)]
    store.selectedConfigID = first.instance_id

    store.selectPreviousConfig()

    #expect(store.selectedConfigID == second.instance_id)
}

@MainActor
@Test func adjacentConfigSelectionStartsAtDirectionalEdgeWhenSelectionIsMissing() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let storage = EasyTierStorage(baseDirectory: directory)
    let first = NetworkConfig(instance_id: "first-id", network_name: "first-network")
    let second = NetworkConfig(instance_id: "second-id", network_name: "second-network")
    let store = EasyTierAppStore(client: UnavailableEasyTierCoreClient(reason: "test"), storage: storage)

    store.configs = [StoredNetworkConfig(config: first), StoredNetworkConfig(config: second)]
    store.selectedConfigID = nil

    store.selectNextConfig()

    #expect(store.selectedConfigID == first.instance_id)

    store.selectedConfigID = nil
    store.selectPreviousConfig()

    #expect(store.selectedConfigID == second.instance_id)
}

@MainActor
@Test func loadFallsBackToFirstConfigWhenSavedSelectionIsMissing() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let storage = EasyTierStorage(baseDirectory: directory)
    let config = NetworkConfig(instance_id: "current-id", network_name: "current-network")
    let snapshot = AppSnapshot(configs: [StoredNetworkConfig(config: config)], mode: .default, lastSelectedConfigID: "missing-id")
    try storage.save(snapshot)

    let store = EasyTierAppStore(client: UnavailableEasyTierCoreClient(reason: "test"), storage: storage)

    await store.load()
    store.stopPolling()

    #expect(store.selectedConfigID == config.instance_id)
    #expect(store.selectedConfig?.network_name == config.network_name)
}

@MainActor
@Test func loadKeepsSavedEmptyConfigList() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let storage = EasyTierStorage(baseDirectory: directory)
    try storage.save(AppSnapshot(configs: [], mode: .default, lastSelectedConfigID: nil))

    let store = EasyTierAppStore(client: UnavailableEasyTierCoreClient(reason: "test"), storage: storage)

    await store.load()
    store.stopPolling()

    #expect(store.configs.isEmpty)
    #expect(store.selectedConfigID == nil)
}

@MainActor
@Test func applyModeConfiguresRPCPortal() async throws {
    let client = RecordingToggleClient()
    let store = EasyTierAppStore(client: client)

    await store.applyMode(.normal(
        rpcPortal: "tcp://0.0.0.0:15998",
        rpcListenEnabled: true,
        rpcListenPort: 15_998,
        rpcPortalWhitelist: ["127.0.0.0/8", "10.126.126.0/24"],
        configServerURL: nil
    ))
    await store.applyMode(.normal(
        rpcPortal: nil,
        rpcListenEnabled: false,
        rpcListenPort: 15_998,
        rpcPortalWhitelist: ["127.0.0.0/8"],
        configServerURL: nil
    ))

    #expect(client.configuredRPCPortals == ["tcp://0.0.0.0:15998", nil])
    #expect(client.configuredRPCPortalWhitelists == [["127.0.0.0/8", "10.126.126.0/24"], ["127.0.0.0/8"]])
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

@MainActor
@Test func selectedRunningInstanceUsesLegacyRuntimeNameWhenConfigNameIsUnique() throws {
    let config = NetworkConfig(instance_id: "config-id", network_name: "legacy-runtime-name")
    let store = EasyTierAppStore(client: UnavailableEasyTierCoreClient(reason: "test"))

    store.configs = [StoredNetworkConfig(config: config)]
    store.selectedConfigID = config.instance_id
    store.instances = [NetworkInstance(instance_id: config.network_name, name: config.network_name, running: true)]

    let selected = try #require(store.selectedRunningInstance)
    #expect(selected.instance_id == config.network_name)
}

@MainActor
@Test func restartSelectedConfigStopsOldRuntimeNameBeforeRunningUpdatedConfig() async {
    let original = NetworkConfig(instance_id: "config-id", network_name: "old-network")
    var updated = original
    updated.network_name = "new-network"
    let client = RecordingToggleClient()
    let store = EasyTierAppStore(client: client)
    let runningInstance = NetworkInstance(instance_id: original.network_name, name: original.network_name, running: true)

    store.configs = [StoredNetworkConfig(config: original)]
    store.selectedConfigID = original.instance_id
    store.instances = [runningInstance]
    store.updateConfig(id: original.instance_id, with: updated)

    await store.restartSelectedConfig(replacing: runningInstance)

    #expect(client.stoppedInstanceNames == [[original.network_name]])
    #expect(client.runConfigs.map(\.network_name) == [updated.network_name])
}

@MainActor
@Test func selectedRunningInstanceDoesNotUseAmbiguousNameFallback() {
    let first = NetworkConfig(instance_id: "first-id", network_name: "shared-network")
    let second = NetworkConfig(instance_id: "second-id", network_name: "shared-network")
    let store = EasyTierAppStore(client: UnavailableEasyTierCoreClient(reason: "test"))

    store.configs = [StoredNetworkConfig(config: first), StoredNetworkConfig(config: second)]
    store.selectedConfigID = second.instance_id
    store.instances = [NetworkInstance(instance_id: "shared-network", name: "shared-network", running: true)]

    #expect(store.selectedRunningInstance == nil)
    #expect(!store.selectedConfigIsRunning)
}

@MainActor
@Test func toggleSelectedConfigConnectionRunsSelectedStoppedNetwork() async {
    let first = NetworkConfig(instance_id: "first-id", network_name: "first-network")
    var second = NetworkConfig(instance_id: "second-id", network_name: "second-network")
    second.listener_urls = ["tcp://0.0.0.0:12010", "udp://0.0.0.0:12010", "wg://0.0.0.0:12011"]
    let client = RecordingToggleClient()
    let store = EasyTierAppStore(client: client)

    store.configs = [StoredNetworkConfig(config: first), StoredNetworkConfig(config: second)]
    store.selectedConfigID = second.instance_id
    store.instances = [NetworkInstance(instance_id: first.instance_id, name: first.network_name, running: true)]

    await store.toggleSelectedConfigConnection()

    #expect(client.runConfigs.map(\.instance_id) == [second.instance_id])
    #expect(client.stoppedInstanceNames.isEmpty)
    #expect(client.retainedInstanceNames.isEmpty)
}

@MainActor
@Test func toggleSelectedConfigConnectionStopsOnlySelectedRunningNetwork() async {
    let first = NetworkConfig(instance_id: "first-id", network_name: "first-network")
    let second = NetworkConfig(instance_id: "second-id", network_name: "second-network")
    let client = RecordingToggleClient()
    let store = EasyTierAppStore(client: client)

    store.configs = [StoredNetworkConfig(config: first), StoredNetworkConfig(config: second)]
    store.selectedConfigID = second.instance_id
    store.instances = [
        NetworkInstance(instance_id: first.instance_id, name: first.network_name, running: true),
        NetworkInstance(instance_id: second.instance_id, name: second.network_name, running: true),
    ]

    await store.toggleSelectedConfigConnection()

    #expect(client.stoppedInstanceNames == [[second.network_name]])
    #expect(client.retainedInstanceNames.isEmpty)
    #expect(client.runConfigs.isEmpty)
}

@MainActor
@Test func stopSelectedConfigPersistsRuntimeHostnameBeforeStopping() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let storage = EasyTierStorage(baseDirectory: directory)
    var config = NetworkConfig(instance_id: "device-id", hostname: "old-host", network_name: "office")
    config.listener_urls = ["tcp://0.0.0.0:13010", "udp://0.0.0.0:13010", "wg://0.0.0.0:13011"]
    let client = RecordingToggleClient()
    let store = EasyTierAppStore(client: client, storage: storage)

    store.configs = [StoredNetworkConfig(config: config)]
    store.selectedConfigID = config.instance_id
    store.instances = [NetworkInstance(
        instance_id: config.instance_id,
        name: config.network_name,
        running: true,
        detail: NetworkInstanceRunningInfo(my_node_info: NodeInfo(hostname: "new-host"))
    )]

    await store.stopSelectedConfig()

    #expect(store.configs.first?.config.hostname == "new-host")
    #expect(try storage.load().configs.first?.config.hostname == "new-host")
    #expect(client.stoppedInstanceNames == [[config.network_name]])
}

@MainActor
@Test func runtimeIntentReplaysHostnameWhenRuntimeReturnedToBase() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let client = RecordingToggleClient()
    let store = EasyTierAppStore(client: client, storage: EasyTierStorage(baseDirectory: directory))
    let config = NetworkConfig(instance_id: "11111111-1111-1111-1111-111111111111", network_name: "office")
    store.configs = [StoredNetworkConfig(config: config)]
    store.runtimeIntents = [hostnameIntent(instanceID: config.instance_id, networkName: config.network_name, base: "base", desired: "desired")]
    client.networkInfos = [
        config.instance_id: NetworkInstanceRunningInfo(my_node_info: NodeInfo(hostname: "base")),
    ]

    await store.refreshRuntime()

    #expect(client.jsonRPCCalls.map(\.method) == ["patch_config"])
    #expect(client.runConfigs.isEmpty)
    #expect(client.stoppedInstanceNames.isEmpty)
    let object = try rpcPayloadObject(client.jsonRPCCalls[0].payload)
    let patch = object["patch"] as? [String: Any]
    #expect(patch?["hostname"] as? String == "desired")
    #expect(store.runtimeIntents.first?.status == .pending)
}

@MainActor
@Test func runtimeIntentDoesNotReplayWhenRuntimeAlreadyMatchesDesired() async {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let client = RecordingToggleClient()
    let store = EasyTierAppStore(client: client, storage: EasyTierStorage(baseDirectory: directory))
    let config = NetworkConfig(instance_id: "11111111-1111-1111-1111-111111111111", network_name: "office")
    store.configs = [StoredNetworkConfig(config: config)]
    store.runtimeIntents = [hostnameIntent(instanceID: config.instance_id, networkName: config.network_name, base: "base", desired: "desired")]
    client.networkInfos = [
        config.instance_id: NetworkInstanceRunningInfo(my_node_info: NodeInfo(hostname: "desired")),
    ]

    await store.refreshRuntime()

    #expect(client.jsonRPCCalls.isEmpty)
    #expect(store.runtimeIntents.first?.status == .applied)
}

@MainActor
@Test func runtimeIntentMarksConflictWhenRuntimeHasThirdPartyValue() async {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let client = RecordingToggleClient()
    let store = EasyTierAppStore(client: client, storage: EasyTierStorage(baseDirectory: directory))
    let config = NetworkConfig(instance_id: "11111111-1111-1111-1111-111111111111", network_name: "office")
    store.configs = [StoredNetworkConfig(config: config)]
    store.runtimeIntents = [hostnameIntent(instanceID: config.instance_id, networkName: config.network_name, base: "base", desired: "desired")]
    client.networkInfos = [
        config.instance_id: NetworkInstanceRunningInfo(my_node_info: NodeInfo(hostname: "someone-else")),
    ]

    await store.refreshRuntime()

    #expect(client.jsonRPCCalls.isEmpty)
    #expect(store.runtimeIntents.first?.status == .conflict)
}

@MainActor
@Test func localHostnameRuntimeIntentDoesNotRestartWhenRPCFails() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let storage = EasyTierStorage(baseDirectory: directory)
    let client = RecordingToggleClient()
    client.jsonRPCError = EasyTierCoreError.operationFailed("rpc unavailable")
    let store = EasyTierAppStore(client: client, storage: storage)
    var config = NetworkConfig(instance_id: "11111111-1111-1111-1111-111111111111", hostname: "base", network_name: "office")
    config.listener_urls = ["tcp://0.0.0.0:11010", "udp://0.0.0.0:11010", "wg://0.0.0.0:11011"]
    store.configs = [StoredNetworkConfig(config: config)]
    store.selectedConfigID = config.instance_id
    var updated = config
    updated.hostname = "desired"
    store.updateConfig(id: config.instance_id, with: updated, saveImmediately: true)
    let running = NetworkInstance(
        instance_id: config.instance_id,
        name: config.network_name,
        running: true,
        detail: NetworkInstanceRunningInfo(my_node_info: NodeInfo(hostname: "base"))
    )
    store.instances = [running]

    await store.applyLocalHostnameRuntimeIntent(
        configID: config.instance_id,
        runningInstance: running,
        desiredHostname: "desired",
        baseHostname: "base"
    )

    #expect(client.runConfigs.isEmpty)
    #expect(client.stoppedInstanceNames.isEmpty)
    #expect(client.jsonRPCCalls.map(\.method) == ["patch_config"])
    #expect(store.runtimeIntents.first?.status == .unreachable)
    #expect(try storage.load().configs.first?.config.hostname == "desired")
}

@Test func reverseRuntimeIntentMaterializesPortForwardWithCurrentMemberIP() throws {
    let intent = RuntimeIntent(
        target: RuntimeIntentTarget(networkName: "office", instanceID: "remote-id", isLocal: false),
        kind: .portForwardSet,
        desired: RuntimeIntentDesired(
            reversePortForwards: [
                RuntimeReversePortForwardIntent(
                    targetInstanceID: "source-id",
                    targetPeerID: nil,
                    bindIP: "0.0.0.0",
                    bindPort: 80,
                    targetPort: 8080,
                    proto: "tcp"
                ),
            ]
        ),
        base: RuntimeIntentBase(portForwardFingerprint: "old")
    )
    let members = [
        NetworkMemberStatus(
            id: "peer-1",
            isLocal: false,
            peerID: "200",
            instanceID: "source-id",
            virtualIPv4: "10.126.126.9/24",
            hostname: "source",
            version: "test",
            routeCost: "1",
            tunnelProto: "tcp",
            latency: "-",
            uploadTotal: "-",
            downloadTotal: "-",
            lossRate: "-",
            natType: "-",
            isPublicServer: false,
            txBytes: 0,
            rxBytes: 0
        ),
    ]

    let forwards = try #require(intent.materializedPortForwards(members: members))

    #expect(forwards.count == 1)
    #expect(forwards[0].bind_ip == "0.0.0.0")
    #expect(forwards[0].bind_port == 80)
    #expect(forwards[0].dst_ip == "10.126.126.9")
    #expect(forwards[0].dst_port == 8080)
}

@MainActor
@Test func runSelectedConfigReportsRunningPortConflictBeforeStarting() async {
    var running = NetworkConfig(instance_id: "running-id", network_name: "running")
    running.listener_urls = ["tcp://0.0.0.0:11010"]
    var selected = NetworkConfig(instance_id: "selected-id", network_name: "selected")
    selected.listener_urls = ["tcp://127.0.0.1:11010"]
    let client = RecordingToggleClient()
    let store = EasyTierAppStore(client: client)

    store.configs = [StoredNetworkConfig(config: running), StoredNetworkConfig(config: selected)]
    store.selectedConfigID = selected.instance_id
    store.instances = [NetworkInstance(instance_id: running.instance_id, name: running.network_name, running: true)]

    await store.runSelectedConfig()

    #expect(client.runConfigs.count == 1)
    #expect(store.lastError == nil)
}

@MainActor
@Test func deleteSelectedConfigKeepsConfigWhenRunningInstanceCannotStop() async {
    let config = NetworkConfig(instance_id: "running-id", network_name: "running-network")
    let client = RecordingToggleClient()
    client.stopError = EasyTierCoreError.operationFailed("stop failed")
    let store = EasyTierAppStore(client: client)

    store.configs = [StoredNetworkConfig(config: config)]
    store.selectedConfigID = config.instance_id
    store.instances = [NetworkInstance(instance_id: config.instance_id, name: config.network_name, running: true)]

    await store.deleteSelectedConfig()

    #expect(store.configs.map(\.id) == [config.instance_id])
    #expect(store.selectedConfigID == config.instance_id)
    #expect(client.stoppedInstanceNames == [[config.network_name]])
    #expect(store.lastError?.contains("stop failed") == true)
}

@MainActor
@Test func deleteSelectedConfigCanRemoveLastStoppedConfig() async {
    let config = NetworkConfig(instance_id: "last-id", network_name: "last-network")
    let store = EasyTierAppStore(client: RecordingToggleClient())

    store.configs = [StoredNetworkConfig(config: config)]
    store.selectedConfigID = config.instance_id

    await store.deleteSelectedConfig()

    #expect(store.configs.isEmpty)
    #expect(store.selectedConfigID == nil)
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

    do {
        _ = try await client.listInstances()
        Issue.record("listInstances should fail when FFI is unavailable")
    } catch let error as EasyTierCoreError {
        #expect(error == .ffiUnavailable("missing dylib"))
    } catch {
        Issue.record("unexpected error: \(error)")
    }

    do {
        _ = try await client.collectNetworkInfos()
        Issue.record("collectNetworkInfos should fail when FFI is unavailable")
    } catch let error as EasyTierCoreError {
        #expect(error == .ffiUnavailable("missing dylib"))
    } catch {
        Issue.record("unexpected error: \(error)")
    }

    do {
        _ = try await client.isConfigServerClientConnected()
        Issue.record("isConfigServerClientConnected should fail when FFI is unavailable")
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
    let client = HelperRunErrorClient(
        payload: PrivilegedHelperErrorPayload(
            code: "helperRequiresApproval",
            message: "Approval is pending."
        )
    )
    let config = NetworkConfig(instance_id: "approval-id", network_name: "approval-network")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = EasyTierAppStore(client: client, storage: EasyTierStorage(baseDirectory: directory))

    store.configs = [StoredNetworkConfig(config: config)]
    store.selectedConfigID = config.instance_id

    await store.runSelectedConfig()

    #expect(store.lastError?.contains("Approval is pending.") == true)
    #expect(store.lastErrorIsHelperPermission)
    #expect(store.logLines.contains { $0.text.contains("Error:") && $0.text.contains("Approval is pending.") })
}

@MainActor
@Test func helperUnavailableErrorBecomesModalLastError() async throws {
    let client = HelperRunErrorClient(
        payload: PrivilegedHelperErrorPayload(
            code: "helperUnavailable",
            message: "Privileged helper is enabled but is not responding."
        )
    )
    let config = NetworkConfig(instance_id: "helper-down-id", network_name: "helper-down-network")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = EasyTierAppStore(client: client, storage: EasyTierStorage(baseDirectory: directory))

    store.configs = [StoredNetworkConfig(config: config)]
    store.selectedConfigID = config.instance_id

    await store.runSelectedConfig()

    #expect(store.lastError?.contains("not responding") == true)
    #expect(!store.lastErrorIsHelperPermission)
}

@MainActor
@Test func retryStartAfterHelperApprovalRunsPendingConfigWhenHelperIsEnabled() async throws {
    let client = RecordingToggleClient()
    let backend = HelperRegistrationBackendSpy(status: .requiresApproval)
    let registration = HelperRegistrationService(backend: backend.backend(), refreshOnInit: false)
    let config = NetworkConfig(instance_id: "pending-approval-id", network_name: "pending-approval-network")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = EasyTierAppStore(
        privilegedClient: client,
        inProcessClient: client,
        helperRegistration: registration,
        storage: EasyTierStorage(baseDirectory: directory)
    )

    store.configs = [StoredNetworkConfig(config: config)]
    store.selectedConfigID = config.instance_id

    await store.runSelectedConfig()
    #expect(client.runConfigs.isEmpty)
    #expect(store.lastErrorIsHelperPermission)

    backend.status = .enabled
    await store.retryStartAfterHelperApproval()

    #expect(client.runConfigs.map(\.instance_id) == [config.instance_id])
}

@MainActor
@Test func ensureRegisteredDoesNotReinstallWhenHelperRequiresApproval() async throws {
    let backend = HelperRegistrationBackendSpy(status: .requiresApproval)
    let registration = HelperRegistrationService(backend: backend.backend(), refreshOnInit: false)

    do {
        try await registration.ensureRegistered()
        Issue.record("ensureRegistered should wait for approval")
    } catch let error as PrivilegedHelperError {
        #expect(error == .needsRegistration)
    } catch {
        Issue.record("unexpected error: \(error)")
    }

    #expect(registration.state == .requiresApproval)
    #expect(backend.registerCount == 0)
    #expect(backend.unregisterCount == 0)
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
            "inst_id": "22222222-2222-2222-2222-222222222222",
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
    #expect(members[0].copyableIPv4Address == "10.10.0.1")
    #expect(members[0].natType == "Open Internet")

    #expect(!members[1].isLocal)
    #expect(members[1].instanceID == "22222222-2222-2222-2222-222222222222")
    #expect(members[1].peerID == "200")
    #expect(members[1].virtualIPv4 == "10.10.0.2/24")
    #expect(members[1].copyableIPv4Address == "10.10.0.2")
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

@Test func runtimeInfoTreatsRemotePeerRoutesWithIPv4AsUsable() throws {
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
    let usableJSON = """
    {
      "my_node_info": {
        "hostname": "macbook",
        "peer_id": 100
      },
      "peer_route_pairs": [
        {
          "route": { "peer_id": 200, "ipv4_addr": "10.10.0.2/24", "hostname": "office-mini", "cost": 2 },
          "peer": { "peer_id": 200, "conns": [] }
        }
      ],
      "running": true
    }
    """
    let routesOnlyJSON = """
    {
      "my_node_info": {
        "hostname": "macbook",
        "peer_id": 100
      },
      "routes": [
        { "peer_id": 200, "ipv4_addr": "10.10.0.2/24", "hostname": "office-mini", "cost": 2 }
      ],
      "running": true
    }
    """
    let mixedWithPublicServerJSON = """
    {
      "my_node_info": {
        "hostname": "macbook",
        "peer_id": 100
      },
      "peer_route_pairs": [
        {
          "route": { "peer_id": 200, "hostname": "PublicServer_demo", "cost": 1 },
          "peer": { "peer_id": 200, "conns": [ { "conn_id": "public-server" } ] }
        },
        {
          "route": { "peer_id": 201, "ipv4_addr": "10.10.0.2/24", "hostname": "office-mini", "cost": 1 },
          "peer": { "peer_id": 201, "conns": [] }
        }
      ],
      "running": true
    }
    """

    let waiting = try JSONDecoder().decode(NetworkInstanceRunningInfo.self, from: Data(waitingJSON.utf8))
    let usable = try JSONDecoder().decode(NetworkInstanceRunningInfo.self, from: Data(usableJSON.utf8))
    let routesOnly = try JSONDecoder().decode(NetworkInstanceRunningInfo.self, from: Data(routesOnlyJSON.utf8))
    let mixedWithPublicServer = try JSONDecoder().decode(NetworkInstanceRunningInfo.self, from: Data(mixedWithPublicServerJSON.utf8))

    #expect(!waiting.isFullyConnected)
    #expect(!waiting.isFullyConnected(expectRemotePeers: true))
    #expect(usable.isFullyConnected)
    #expect(usable.isFullyConnected(expectRemotePeers: true))
    #expect(routesOnly.isFullyConnected)
    #expect(routesOnly.isFullyConnected(expectRemotePeers: true))
    #expect(mixedWithPublicServer.isFullyConnected)
    #expect(mixedWithPublicServer.isFullyConnected(expectRemotePeers: true))
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

private func hostnameIntent(instanceID: String, networkName: String, base: String, desired: String) -> RuntimeIntent {
    RuntimeIntent(
        target: RuntimeIntentTarget(
            networkName: networkName,
            instanceID: instanceID,
            recentHostname: base,
            isLocal: true
        ),
        kind: .hostname,
        desired: RuntimeIntentDesired(hostname: desired),
        base: RuntimeIntentBase(hostname: base),
        status: .pending
    )
}

private func rpcPayloadObject(_ payload: String) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
        throw EasyTierCoreError.invalidResponse("RPC payload is not a JSON object")
    }
    return object
}

private final class MemoryNetworkSecretStore: NetworkSecretStore, @unchecked Sendable {
    var secrets: [String: String]
    var deletedIDs: [String] = []
    var readReasons: [String?] = []
    var canAutofill: Bool
    var readError: Error?

    init(secrets: [String: String] = [:], canAutofill: Bool = false) {
        self.secrets = secrets
        self.canAutofill = canAutofill
    }

    func save(_ secret: String, for config: NetworkConfig) throws {
        secrets[config.network_name] = secret
    }

    func secret(for config: NetworkConfig, reason: String?) throws -> String? {
        readReasons.append(reason)
        if let readError { throw readError }
        return secrets[config.network_name]
    }

    func deleteSecret(for config: NetworkConfig) throws {
        deletedIDs.append(config.network_name)
        secrets.removeValue(forKey: config.network_name)
    }

    func containsSecret(for config: NetworkConfig) -> Bool {
        secrets[config.network_name] != nil
    }

    func canAutofillWithBiometrics() -> Bool {
        canAutofill
    }
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
    func configureRPCPortal(_ rpcPortal: String?, whitelist _: [String]?) async throws {
        if rpcPortal != nil { throw EasyTierCoreError.operationFailed("unsupported") }
    }

    func callJSONRPC(service _: String, method _: String, domain _: String?, payload _: String) async throws -> String {
        throw EasyTierCoreError.operationFailed("unsupported")
    }

    func connectRPCClient(clientID _: String, url _: URL) async throws {
        throw EasyTierCoreError.operationFailed("unsupported")
    }

    func disconnectRPCClient(clientID _: String) async throws {}

    func startConfigServerClient(url _: URL) async throws {
        throw EasyTierCoreError.operationFailed("unsupported")
    }

    func stopConfigServerClient() async throws {}
    func isConfigServerClientConnected() async throws -> Bool { false }
}

private final class RecordingToggleClient: EasyTierCoreClient, @unchecked Sendable {
    var runConfigs: [NetworkConfig] = []
    var stoppedInstanceNames: [[String]] = []
    var retainedInstanceNames: [[String]] = []
    var listedInstances: [NetworkInstance] = []
    var networkInfos: [String: NetworkInstanceRunningInfo] = [:]
    var configuredRPCPortals: [String?] = []
    var configuredRPCPortalWhitelists: [[String]?] = []
    var jsonRPCCalls: [EasyTierRPCRequest] = []
    var connectedRPCClients: [(clientID: String, url: URL)] = []
    var stopError: Error?
    var jsonRPCError: Error?

    func version() async throws -> String { "test" }
    func validate(toml _: String) async throws {}

    func run(config: NetworkConfig) async throws {
        runConfigs.append(config)
    }

    func stop(instanceNames: [String]) async throws {
        stoppedInstanceNames.append(instanceNames)
        if let stopError { throw stopError }
    }

    func retain(instanceNames: [String]) async throws {
        retainedInstanceNames.append(instanceNames)
    }

    func listInstances() async throws -> [NetworkInstance] { listedInstances }
    func collectNetworkInfos() async throws -> [String: NetworkInstanceRunningInfo] { networkInfos }
    func configureRPCPortal(_ rpcPortal: String?, whitelist: [String]?) async throws {
        configuredRPCPortals.append(rpcPortal)
        configuredRPCPortalWhitelists.append(whitelist)
    }

    func callJSONRPC(service: String, method: String, domain: String?, payload: String) async throws -> String {
        jsonRPCCalls.append(EasyTierRPCRequest(service: service, method: method, domain: domain, payload: payload))
        if let jsonRPCError { throw jsonRPCError }
        return #"{"ok":true}"#
    }

    func connectRPCClient(clientID: String, url: URL) async throws {
        connectedRPCClients.append((clientID: clientID, url: url))
    }

    func disconnectRPCClient(clientID _: String) async throws {}

    func startConfigServerClient(url _: URL) async throws {
        throw EasyTierCoreError.operationFailed("unsupported")
    }

    func stopConfigServerClient() async throws {}
    func isConfigServerClientConnected() async throws -> Bool { false }
}

private final class RecordingSystemSleepPreventer: SystemSleepPreventing, @unchecked Sendable {
    private(set) var calls: [(prevented: Bool, reason: String)] = []
    private(set) var isPreventingSystemSleep = false

    func setSystemSleepPrevented(_ prevented: Bool, reason: String) {
        guard isPreventingSystemSleep != prevented else { return }
        isPreventingSystemSleep = prevented
        calls.append((prevented, reason))
    }
}

@MainActor
private final class HelperRegistrationBackendSpy {
    var status: SMAppService.Status
    var registerCount = 0
    var unregisterCount = 0

    init(status: SMAppService.Status) {
        self.status = status
    }

    func backend() -> HelperRegistrationService.Backend {
        HelperRegistrationService.Backend(
            status: { self.status },
            register: { self.registerCount += 1 },
            unregister: { self.unregisterCount += 1 },
            useLegacyInstaller: { false },
            legacyIsInstalled: { false },
            installLegacy: {}
        )
    }
}

private final class HelperRunErrorClient: EasyTierCoreClient, @unchecked Sendable {
    let payload: PrivilegedHelperErrorPayload

    init(payload: PrivilegedHelperErrorPayload) {
        self.payload = payload
    }

    func version() async throws -> String { "test" }
    func validate(toml _: String) async throws {}

    func run(config _: NetworkConfig) async throws {
        throw PrivilegedHelperError.helperReported(payload)
    }

    func stop(instanceNames _: [String]) async throws {}
    func retain(instanceNames _: [String]) async throws {}
    func listInstances() async throws -> [NetworkInstance] { [] }
    func collectNetworkInfos() async throws -> [String: NetworkInstanceRunningInfo] { [:] }
    func configureRPCPortal(_: String?, whitelist _: [String]?) async throws {}
    func callJSONRPC(service _: String, method _: String, domain _: String?, payload _: String) async throws -> String { "" }
    func connectRPCClient(clientID _: String, url _: URL) async throws {}
    func disconnectRPCClient(clientID _: String) async throws {}
    func startConfigServerClient(url _: URL) async throws {}
    func stopConfigServerClient() async throws {}
    func isConfigServerClientConnected() async throws -> Bool { false }
}
