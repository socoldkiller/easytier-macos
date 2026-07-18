import AppKit
import Foundation
import LocalAuthentication
import Security
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
    #expect(config.hostname == NetworkConfig.defaultHostname)
    #expect(config.mtu == NetworkConfig.defaultMTU)
    #expect(!NetworkConfig.defaultHostname.isEmpty)
}

@Test func defaultConfigUsesBasicMode() {
    let config = NetworkConfig()

    #expect(config.advanced_settings == false)
    #expect(config.peer_urls == [])
    #expect(config.network_secret == "")
}

@Test func magicDNSSettingsNormalizeAndValidateSuffix() throws {
    #expect(MagicDNSSettings.default.dnsSuffix == "et.net.")
    #expect(try MagicDNSSettings(dnsSuffix: "example.internal").dnsSuffix == "example.internal.")
    #expect(try MagicDNSSettings(dnsSuffix: "et.local").dnsSuffix == "et.local.")
    #expect(try MagicDNSSettings(dnsSuffix: "  LAB.Example  ").dnsSuffix == "lab.example.")
    #expect(try MagicDNSSettings(dnsSuffix: "").dnsSuffix == "et.net.")

    #expect(throws: MagicDNSSettingsValidationError.self) {
        _ = try MagicDNSSettings(dnsSuffix: "https://example.internal")
    }
    #expect(throws: MagicDNSSettingsValidationError.self) {
        _ = try MagicDNSSettings(dnsSuffix: "bad_suffix.local")
    }
    #expect(throws: MagicDNSSettingsValidationError.self) {
        _ = try MagicDNSSettings(dnsSuffix: "bad..local")
    }
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
    config.dev_name = "utun9"
    config.use_smoltcp = true
    config.enable_kcp_proxy = true
    config.disable_kcp_input = true
    config.enable_quic_proxy = true
    config.disable_quic_input = true
    config.disable_p2p = true
    config.p2p_only = true
    config.lazy_p2p = true
    config.relay_all_peer_rpc = true
    config.need_p2p = true
    config.proxy_forward_by_system = true
    config.disable_tcp_hole_punching = true
    config.disable_udp_hole_punching = true
    config.disable_upnp = true
    config.enable_udp_broadcast_relay = true
    config.disable_sym_hole_punching = true
    config.enable_relay_network_whitelist = true
    config.relay_network_whitelist = ["office", "edge*"]
    config.mtu = 1_300
    config.instance_recv_bps_limit = 1024
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
    #expect(decoded.dev_name == "utun9")
    #expect(decoded.use_smoltcp == true)
    #expect(decoded.enable_kcp_proxy == true)
    #expect(decoded.disable_kcp_input == true)
    #expect(decoded.enable_quic_proxy == true)
    #expect(decoded.disable_quic_input == true)
    #expect(decoded.disable_p2p == true)
    #expect(decoded.p2p_only == true)
    #expect(decoded.lazy_p2p == true)
    #expect(decoded.relay_all_peer_rpc == true)
    #expect(decoded.need_p2p == true)
    #expect(decoded.proxy_forward_by_system == true)
    #expect(decoded.disable_tcp_hole_punching == true)
    #expect(decoded.disable_udp_hole_punching == true)
    #expect(decoded.disable_upnp == true)
    #expect(decoded.enable_udp_broadcast_relay == true)
    #expect(decoded.disable_sym_hole_punching == true)
    #expect(decoded.enable_relay_network_whitelist == true)
    #expect(decoded.relay_network_whitelist == ["office", "edge*"])
    #expect(decoded.mtu == 1_300)
    #expect(decoded.instance_recv_bps_limit == 1024)
    #expect(decoded.enable_magic_dns == true)
}

@MainActor
@Test func importTOMLGeneratesNewInstanceIDWhenImportedIDAlreadyExists() async throws {
    let config = NetworkConfig(instance_id: "duplicate-id", network_name: "office")
    let store = EasyTierAppStore()
    store.configs = [config]

    await store.importTOML(try NetworkConfigTOMLCodec.encode(config))

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
    #expect(toml.contains("ipv6_public_addr_auto = true"))
    #expect(toml.contains("accept_dns = true"))
    #expect(toml.contains("private_mode = true"))
    #expect(!toml.contains("disable_encryption"))
    #expect(!toml.contains("disable_ipv6"))
    #expect(!toml.contains("enable_magic_dns"))
    #expect(!toml.contains("enable_private_mode"))

    let decoded = try NetworkConfigTOMLCodec.decode(toml)
    #expect(decoded.disable_encryption == true)
    #expect(decoded.disable_ipv6 == true)
    #expect(decoded.ipv6_public_addr_auto == true)
    #expect(decoded.enable_magic_dns == true)
    #expect(decoded.enable_private_mode == true)
}

@Test func tomlMagicDNSSuffixIsOnlyWrittenBySettingsOverlay() throws {
    var config = NetworkConfig()
    config.enable_magic_dns = true

    let plainTOML = try NetworkConfigTOMLCodec.encode(config)
    #expect(plainTOML.contains("accept_dns = true"))
    #expect(!plainTOML.contains("tld_dns_zone"))

    let overlayTOML = try NetworkConfigTOMLCodec.encode(
        config,
        magicDNSSettings: try MagicDNSSettings(dnsSuffix: "lab.internal")
    )
    #expect(overlayTOML.contains("accept_dns = true"))
    #expect(overlayTOML.contains("tld_dns_zone = \"lab.internal.\""))
    #expect(try NetworkConfigTOMLCodec.metadata(from: overlayTOML).magicDNSSuffix == "lab.internal.")

    config.enable_magic_dns = false
    let disabledTOML = try NetworkConfigTOMLCodec.encode(
        config,
        magicDNSSettings: try MagicDNSSettings(dnsSuffix: "lab.internal")
    )
    #expect(!disabledTOML.contains("tld_dns_zone"))
}

@Test func magicDNSSystemResolverConfigurationUsesConfiguredTLD() throws {
    var config = NetworkConfig()
    config.enable_magic_dns = true
    let toml = try NetworkConfigTOMLCodec.encode(
        config,
        magicDNSSettings: try MagicDNSSettings(dnsSuffix: "et.local")
    )

    let parsedResolverConfig = try MagicDNSSystemResolverConfigurator.configuration(from: toml)
    let resolverConfig = try #require(parsedResolverConfig)

    #expect(resolverConfig.dnsSuffix == "et.local.")
    #expect(resolverConfig.resolverFileName == "et.local")
}

@Test func magicDNSSystemResolverWritesConfiguredTLDResolver() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try "# Added by easytier\nnameserver 100.100.100.101\n".write(
        to: directory.appendingPathComponent("old.internal"),
        atomically: true,
        encoding: .utf8
    )
    try "nameserver 8.8.8.8\n".write(
        to: directory.appendingPathComponent("example.com"),
        atomically: true,
        encoding: .utf8
    )

    let configurator = MagicDNSSystemResolverConfigurator(resolverDirectory: directory)
    try configurator.apply(try MagicDNSSystemResolverConfiguration(dnsSuffix: "et.local"))

    let resolver = try String(contentsOf: directory.appendingPathComponent("et.local"), encoding: .utf8)
    let search = try String(contentsOf: directory.appendingPathComponent("search.easytier"), encoding: .utf8)

    #expect(resolver == "# Added by easytier\ndomain et.local\nnameserver 100.100.100.101\n")
    #expect(search == "# Added by easytier\nsearch et.local\n")
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("old.internal").path))
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("example.com").path))
}

@Test func magicDNSSystemResolverRemovesOnlyManagedResolverFiles() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try "# Added by easytier\ndomain et.net\nnameserver 100.100.100.101\n".write(
        to: directory.appendingPathComponent("et.net"),
        atomically: true,
        encoding: .utf8
    )
    try "# Added by easytier\nsearch et.net\n".write(
        to: directory.appendingPathComponent("search.easytier"),
        atomically: true,
        encoding: .utf8
    )
    try "nameserver 8.8.8.8\n".write(
        to: directory.appendingPathComponent("example.com"),
        atomically: true,
        encoding: .utf8
    )

    let configurator = MagicDNSSystemResolverConfigurator(resolverDirectory: directory)
    try configurator.removeManagedResolverFiles()

    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("et.net").path))
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("search.easytier").path))
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("example.com").path))
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

@Test func tomlDecodesPrivateModePeerConfig() throws {
    let toml = """
    instance_name = "example-instance"
    hostname = "example-host"
    ipv4 = "192.0.2.10/24"
    dhcp = false
    listeners = [ "tcp://0.0.0.0:11010", "udp://0.0.0.0:11010", "wg://0.0.0.0:11011" ]

    [network_identity]
    network_name = "example-network"
    network_secret = "example-secret"

    [[peer]]
    uri = "tcp://peer.example.test:11010"

    [flags]
    private_mode = true
    """

    _ = try NetworkConfigTOMLCodec.metadata(from: toml)
    let decoded = try NetworkConfigTOMLCodec.decode(toml)

    #expect(decoded.network_name == "example-network")
    #expect(decoded.hostname == "example-host")
    #expect(decoded.virtual_ipv4 == "192.0.2.10")
    #expect(decoded.network_length == 24)
    #expect(decoded.peer_urls == ["tcp://peer.example.test:11010"])
    #expect(decoded.enable_private_mode == true)
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
        configIDs: [config.id],
        mode: .default,
        lastSelectedConfigID: "abc",
        vpnOnDemandEnabled: true
    )

    try storage.save(snapshot, configs: [config])

    let state = try String(contentsOf: directory.appendingPathComponent("state.json"), encoding: .utf8)
    let tomlURL = directory.appendingPathComponent("configs/lab-id.toml")
    let toml = try String(contentsOf: tomlURL, encoding: .utf8)
    let stateObject = try #require(JSONSerialization.jsonObject(with: Data(state.utf8)) as? [String: Any])
    let stateConfigIDs = try #require(stateObject["configIDs"] as? [String])

    #expect(stateObject["schemaVersion"] as? Int == AppSnapshot.currentSchemaVersion)
    #expect(stateConfigIDs == ["lab-id"])
    #expect(!state.contains("network_name"))
    #expect(!state.contains("network_secret"))
    #expect(!state.contains("port_forwards"))
    #expect(FileManager.default.fileExists(atPath: tomlURL.path))
    #expect(toml.contains("network_name = \"lab\""))

    let loaded = try storage.load()

    #expect(loaded.configs.first?.network_name == "lab")
    #expect(loaded.snapshot.mode == .default)
    #expect(loaded.snapshot.lastSelectedConfigID == "abc")
    #expect(loaded.snapshot.vpnOnDemandEnabled)
}

@MainActor
@Test func appQuitStopsNetworkAndShutdownsHelperWhenVpnOnDemandIsOff() async {
    let client = RecordingToggleClient()
    let config = NetworkConfig(instance_id: "quit-id", network_name: "office")
    let store = EasyTierAppStore(client: client)

    store.configs = [config]
    store.selectedConfigID = config.instance_id
    store.instances = [NetworkInstance(instance_id: config.instance_id, name: config.network_name, running: true)]

    await store.prepareForAppQuit()

    #expect(client.retainedInstanceNames == [[]])
    #expect(client.shutdownCount == 1)
}

@MainActor
@Test func appQuitLeavesNetworkAndHelperRunningWhenVpnOnDemandIsOn() async {
    let client = RecordingToggleClient()
    let config = NetworkConfig(instance_id: "quit-ondemand-id", network_name: "office")
    let store = EasyTierAppStore(client: client)

    store.configs = [config]
    store.selectedConfigID = config.instance_id
    store.instances = [NetworkInstance(instance_id: config.instance_id, name: config.network_name, running: true)]
    store.vpnOnDemandEnabled = true

    await store.prepareForAppQuit()

    #expect(client.retainedInstanceNames.isEmpty)
    #expect(client.shutdownCount == 0)
}

@MainActor
@Test func appQuitStopsInProcessNetworkWhenVpnOnDemandIsOn() async {
    let client = RecordingToggleClient()
    let config = NetworkConfig(instance_id: "quit-notun-id", network_name: "office", no_tun: true)
    let store = EasyTierAppStore(client: client)

    store.configs = [config]
    store.selectedConfigID = config.instance_id
    store.instances = [NetworkInstance(instance_id: config.instance_id, name: config.network_name, running: true)]
    store.vpnOnDemandEnabled = true

    await store.prepareForAppQuit()

    #expect(client.stoppedInstanceNames == [[config.network_name]])
    #expect(client.retainedInstanceNames.isEmpty)
    #expect(client.shutdownCount == 0)
}

@MainActor
@Test func softwareUpdateStopsNetworkAndHelperEvenWithVpnOnDemand() async {
    let client = RecordingToggleClient()
    let config = NetworkConfig(instance_id: "update-id", network_name: "office")
    let store = EasyTierAppStore(client: client)

    store.configs = [config]
    store.selectedConfigID = config.instance_id
    store.instances = [NetworkInstance(instance_id: config.instance_id, name: config.network_name, running: true)]
    store.vpnOnDemandEnabled = true

    #expect(store.runningConfigIDsForSoftwareUpdate() == [config.instance_id])

    await store.prepareForSoftwareUpdate()

    #expect(client.retainedInstanceNames == [[]])
    #expect(client.shutdownCount == 1)
    #expect(store.isQuitting)
}

@MainActor
@Test func softwareUpdateRestoreStartsRequestedConfigurationOnce() async {
    let client = RecordingToggleClient()
    let config = NetworkConfig(instance_id: "restore-id", network_name: "office", no_tun: true)
    let store = EasyTierAppStore(client: client)

    store.configs = [config]
    store.selectedConfigID = config.instance_id

    await store.restoreConfigsAfterSoftwareUpdate(configIDs: [config.instance_id, "missing-id"])

    #expect(client.runConfigs.map(\.instance_id) == [config.instance_id])
    #expect(!store.isQuitting)
}

@MainActor
@Test func appStoreExplicitlySavesNetworkSecretInKeychainNotToml() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let storage = EasyTierStorage(baseDirectory: directory)
    let secrets = MemoryNetworkSecretStore()
    let config = NetworkConfig(instance_id: "secret-id", network_name: "lab", network_secret: "super-secret")
    let store = EasyTierAppStore(
        client: RecordingToggleClient(),
        storage: storage,
        networkSecretStore: secrets
    )

    try await store.saveNetworkSecretToKeychain("super-secret", for: config)
    var persistedConfig = config
    persistedConfig.network_secret = nil
    store.configs = [persistedConfig]
    store.selectedConfigID = config.instance_id
    store.save()

    let toml = try String(contentsOf: directory.appendingPathComponent("configs/secret-id.toml"), encoding: .utf8)

    #expect(secrets.secrets["lab"] == "super-secret")
    #expect(!toml.contains("super-secret"))
    #expect(store.configs.first?.network_secret?.nilIfEmpty == nil)
}

@MainActor
@Test func genericConfigPersistenceNeverImplicitlyWritesKeychain() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let storage = EasyTierStorage(baseDirectory: directory)
    let secrets = MemoryNetworkSecretStore()
    let config = NetworkConfig(
        instance_id: "sanitized-save-id",
        network_name: "office",
        network_secret: "must-not-be-written-implicitly"
    )
    let store = EasyTierAppStore(
        client: RecordingToggleClient(),
        storage: storage,
        networkSecretStore: secrets
    )
    store.configs = [config]
    store.selectedConfigID = config.id

    store.save()

    let toml = try String(
        contentsOf: directory.appendingPathComponent("configs/sanitized-save-id.toml"),
        encoding: .utf8
    )
    #expect(secrets.secrets.isEmpty)
    #expect(!toml.contains("must-not-be-written-implicitly"))
    #expect(store.configs.first?.network_secret?.nilIfEmpty == nil)
}

@MainActor
@Test func verifiedSaveSurfacesLegacyCleanupAsANonblockingNotice() async throws {
    let secrets = MemoryNetworkSecretStore()
    secrets.saveCleanup = .pending([
        NetworkSecretCleanupIssue(backend: .legacy, status: errSecAuthFailed),
    ])
    let config = NetworkConfig(instance_id: "cleanup-notice-id", network_name: "office")
    let store = EasyTierAppStore(
        client: RecordingToggleClient(),
        networkSecretStore: secrets
    )

    try await store.saveNetworkSecretToKeychain("secret", for: config)

    #expect(store.networkSecretCleanupNotice != nil)
    #expect(store.lastError == nil)
    store.dismissNetworkSecretCleanupNotice()
    #expect(store.networkSecretCleanupNotice == nil)
}

@MainActor
@Test func runSelectedConfigUsesKeychainNetworkSecret() async throws {
    let client = RecordingToggleClient()
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "run-secret"])
    let config = NetworkConfig(instance_id: "run-id", network_name: "office", network_secret: nil)
    let store = EasyTierAppStore(client: client, networkSecretStore: secrets)

    store.configs = [config]
    store.selectedConfigID = config.instance_id

    await store.runSelectedConfig()

    #expect(client.runConfigs.first?.network_secret == "run-secret")
    #expect(secrets.readPurposes == [.run])
    #expect(secrets.savePurposes.isEmpty)
}

@MainActor
@Test func runSelectedConfigPersistsEnteredSecretForTheNextLaunch() async {
    let firstClient = RecordingToggleClient()
    let secondClient = RecordingToggleClient()
    let secrets = MemoryNetworkSecretStore()
    let config = NetworkConfig(instance_id: "entered-secret-run-id", network_name: "office", network_secret: nil)
    let firstStore = EasyTierAppStore(client: firstClient, networkSecretStore: secrets)

    firstStore.configs = [config]
    firstStore.selectedConfigID = config.instance_id

    let outcome = await firstStore.runSelectedConfig(
        networkSecretInput: .edited("typed-secret")
    )

    #expect(firstClient.runConfigs.first?.network_secret == "typed-secret")
    #expect(secrets.secrets["office"] == "typed-secret")
    #expect(outcome.didPersistEditedSecret)
    #expect(secrets.savePurposes == [.update])
    #expect(secrets.readPurposes.isEmpty)

    let relaunchedStore = EasyTierAppStore(client: secondClient, networkSecretStore: secrets)
    relaunchedStore.configs = [config]
    relaunchedStore.selectedConfigID = config.instance_id

    await relaunchedStore.runSelectedConfig()

    #expect(secondClient.runConfigs.first?.network_secret == "typed-secret")
}

@MainActor
@Test func explicitKeychainSaveAndRemoveWorkWithoutRunningTheNetwork() async throws {
    let secrets = MemoryNetworkSecretStore()
    let config = NetworkConfig(instance_id: "explicit-save-id", network_name: "office")
    let store = EasyTierAppStore(
        client: RecordingToggleClient(),
        networkSecretStore: secrets
    )

    #expect(!(try await store.hasSavedNetworkSecret(for: config)))
    try await store.saveNetworkSecretToKeychain("saved-secret", for: config)
    #expect(try await store.hasSavedNetworkSecret(for: config))
    #expect(secrets.secrets["office"] == "saved-secret")

    try await store.removeNetworkSecretFromKeychain(for: config)
    #expect(!(try await store.hasSavedNetworkSecret(for: config)))
}

@MainActor
@Test func runSelectedConfigUsesAnAlreadyLoadedSecretWithoutKeychainAccess() async {
    let client = RecordingToggleClient()
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "keychain-secret"])
    let config = NetworkConfig(instance_id: "loaded-secret-run-id", network_name: "office")
    let store = EasyTierAppStore(client: client, networkSecretStore: secrets)
    store.configs = [config]
    store.selectedConfigID = config.id

    let outcome = await store.runSelectedConfig(
        networkSecretInput: .saved("loaded-secret")
    )

    #expect(client.runConfigs.first?.network_secret == "loaded-secret")
    #expect(!outcome.didPersistEditedSecret)
    #expect(secrets.savePurposes.isEmpty)
    #expect(secrets.readPurposes.isEmpty)
}

@MainActor
@Test func foregroundRestartReusesTheRuntimeSecretSessionCache() async {
    let client = RecordingToggleClient()
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "saved-secret"])
    let config = NetworkConfig(instance_id: "cached-restart-id", network_name: "office")
    let running = NetworkInstance(
        instance_id: config.id,
        name: config.network_name,
        running: true
    )
    let store = EasyTierAppStore(client: client, networkSecretStore: secrets)
    store.configs = [config]
    store.selectedConfigID = config.id

    await store.runSelectedConfig()
    store.instances = [running]
    await store.stopSelectedConfig()
    store.instances = []
    await store.runSelectedConfig()
    store.instances = [running]
    await store.restartSelectedConfig(replacing: running, configID: config.id)

    #expect(secrets.readPurposes == [.run])
    #expect(secrets.savePurposes.isEmpty)
    #expect(client.runConfigs.map(\.network_secret) == [
        "saved-secret",
        "saved-secret",
        "saved-secret",
    ])
}

@MainActor
@Test func applicationFocusLossKeepsTheRuntimeSecretSessionCache() async {
    let client = RecordingToggleClient()
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "saved-secret"])
    let config = NetworkConfig(instance_id: "inactive-cache-id", network_name: "office")
    let running = NetworkInstance(
        instance_id: config.id,
        name: config.network_name,
        running: true
    )
    let store = EasyTierAppStore(client: client, networkSecretStore: secrets)
    store.configs = [config]
    store.selectedConfigID = config.id

    await store.runSelectedConfig()
    store.instances = [running]
    await store.stopSelectedConfig()
    store.instances = []
    store.handleApplicationDidResignActive()
    await store.runSelectedConfig()

    #expect(secrets.readPurposes == [.run])
    #expect(secrets.savePurposes.isEmpty)
    #expect(secrets.authenticationInvalidationCount == 0)
}

@MainActor
@Test func applicationHideClearsTheRuntimeSecretSessionCache() async {
    let client = RecordingToggleClient()
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "saved-secret"])
    let config = NetworkConfig(instance_id: "hidden-cache-id", network_name: "office")
    let running = NetworkInstance(
        instance_id: config.id,
        name: config.network_name,
        running: true
    )
    let store = EasyTierAppStore(client: client, networkSecretStore: secrets)
    store.configs = [config]
    store.selectedConfigID = config.id

    await store.runSelectedConfig()
    store.instances = [running]
    await store.stopSelectedConfig()
    store.instances = []
    store.handleApplicationDidHide()
    await store.runSelectedConfig()

    #expect(secrets.readPurposes == [.run, .run])
    #expect(secrets.authenticationInvalidationCount == 1)
}

@MainActor
@Test func applicationFocusLossDoesNotCancelAnInFlightNetworkStartSecretRead() async {
    let client = RecordingToggleClient()
    let secrets = BlockingNetworkSecretStore(secret: "saved-secret")
    let config = NetworkConfig(instance_id: "focus-loss-start-id", network_name: "office")
    let store = EasyTierAppStore(client: client, networkSecretStore: secrets)
    store.configs = [config]
    store.selectedConfigID = config.id

    let runTask = Task { await store.runSelectedConfig() }
    defer { secrets.releaseReads() }

    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while secrets.readCount == 0, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(secrets.readCount == 1)

    store.handleApplicationDidResignActive()
    #expect(secrets.authenticationInvalidationCount == 0)
    secrets.releaseReads()
    _ = await runTask.value

    #expect(client.runConfigs.first?.network_secret == "saved-secret")
}

@MainActor
@Test func manualRestartPersistsAnEditedSecretExactlyOnce() async {
    let client = RecordingToggleClient()
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "old-secret"])
    let config = NetworkConfig(instance_id: "edited-restart-id", network_name: "office")
    let running = NetworkInstance(
        instance_id: config.id,
        name: config.network_name,
        running: true
    )
    let store = EasyTierAppStore(client: client, networkSecretStore: secrets)
    store.configs = [config]
    store.selectedConfigID = config.id
    store.instances = [running]

    let outcome = await store.restartSelectedConfig(
        replacing: running,
        configID: config.id,
        networkSecretInput: .edited("new-secret")
    )

    #expect(outcome.didPersistEditedSecret)
    #expect(secrets.savePurposes == [.update])
    #expect(secrets.readPurposes.isEmpty)
    #expect(secrets.secrets["office"] == "new-secret")
    #expect(client.runConfigs.first?.network_secret == "new-secret")
}

@MainActor
@Test func deletingASecretClearsTheRuntimeSecretSessionCache() async throws {
    let client = RecordingToggleClient()
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "first-secret"])
    let config = NetworkConfig(instance_id: "delete-cache-id", network_name: "office")
    let running = NetworkInstance(
        instance_id: config.id,
        name: config.network_name,
        running: true
    )
    let store = EasyTierAppStore(client: client, networkSecretStore: secrets)
    store.configs = [config]
    store.selectedConfigID = config.id

    await store.runSelectedConfig()
    store.instances = [running]
    await store.stopSelectedConfig()
    store.instances = []
    try await store.removeNetworkSecretFromKeychain(for: config)
    secrets.secrets["office"] = "replacement-secret"
    await store.runSelectedConfig()

    #expect(secrets.readPurposes == [.run, .run])
    #expect(secrets.deletePurposes == [.delete])
    #expect(client.runConfigs.last?.network_secret == "replacement-secret")
}

@MainActor
@Test func applicationFocusLossDoesNotCancelAnInFlightNetworkDeletion() async {
    let secrets = BlockingNetworkSecretStore(secret: "saved-secret")
    let config = NetworkConfig(instance_id: "focus-loss-delete-id", network_name: "office")
    let store = EasyTierAppStore(
        client: RecordingToggleClient(),
        networkSecretStore: secrets
    )
    store.configs = [config]
    store.selectedConfigID = config.id

    let deleteTask = Task { await store.deleteSelectedConfig() }
    defer { secrets.releaseDeletes() }

    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while secrets.deleteCount == 0, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(secrets.deleteCount == 1)

    store.handleApplicationDidResignActive()
    #expect(secrets.authenticationInvalidationCount == 0)
    secrets.releaseDeletes()
    await deleteTask.value

    #expect(store.configs.isEmpty)
    #expect(store.lastError == nil)
    #expect(secrets.authenticationInvalidationCount == 1)
}

@MainActor
@Test func runSelectedConfigDoesNotStartWhenEnteredSecretCannotBeSaved() async {
    let client = RecordingToggleClient()
    let secrets = MemoryNetworkSecretStore()
    secrets.saveError = EasyTierCoreError.operationFailed("keychain write failed")
    let config = NetworkConfig(instance_id: "failed-secret-save-id", network_name: "office")
    let store = EasyTierAppStore(client: client, networkSecretStore: secrets)

    store.configs = [config]
    store.selectedConfigID = config.instance_id

    let outcome = await store.runSelectedConfig(
        networkSecretInput: .edited("typed-secret")
    )

    #expect(client.runConfigs.isEmpty)
    #expect(store.lastError?.contains("keychain write failed") == true)
    #expect(!outcome.didPersistEditedSecret)
    #expect(secrets.savePurposes == [.update])
    #expect(secrets.readPurposes.isEmpty)

    secrets.saveError = nil
    secrets.secrets["office"] = "saved-secret"
    await store.runSelectedConfig()

    #expect(secrets.readPurposes == [.run])
    #expect(client.runConfigs.first?.network_secret == "saved-secret")
}

@MainActor
@Test func canceledEditedSecretSavePreservesTheDraftAndDoesNotSurfaceAGlobalError() async {
    let client = RecordingToggleClient()
    let secrets = MemoryNetworkSecretStore()
    secrets.saveError = NetworkSecretStoreError.keychain(errSecUserCanceled)
    let config = NetworkConfig(instance_id: "canceled-edited-secret-id", network_name: "office")
    let input = NetworkSecretInput.edited("typed-secret")
    let store = EasyTierAppStore(client: client, networkSecretStore: secrets)
    store.configs = [config]
    store.selectedConfigID = config.id

    let outcome = await store.runSelectedConfig(networkSecretInput: input)

    #expect(!outcome.didPersistEditedSecret)
    #expect(input.applying(outcome) == input)
    #expect(store.lastError == nil)
    #expect(client.runConfigs.isEmpty)
    #expect(secrets.savePurposes == [.update])
}

@MainActor
@Test func runSelectedConfigDoesNotStartAfterQuitBegins() async {
    let client = RecordingToggleClient()
    let config = NetworkConfig(instance_id: "quit-guard-id", network_name: "quit-guard-network")
    let store = EasyTierAppStore(client: client)
    store.configs = [config]
    store.selectedConfigID = config.instance_id
    store.isQuitting = true

    await store.runSelectedConfig()

    #expect(client.runConfigs.isEmpty)
}

@MainActor
@Test func restartTargetsConfigMatchingOriginalInstanceAfterSelectionChanges() async {
    let client = RecordingToggleClient()
    let originalConfig = NetworkConfig(instance_id: "restart-original-id", network_name: "restart-original")
    let newlySelectedConfig = NetworkConfig(instance_id: "restart-selected-id", network_name: "restart-selected")
    let originalInstance = NetworkInstance(
        instance_id: originalConfig.instance_id,
        name: originalConfig.network_name,
        running: true
    )
    let store = EasyTierAppStore(client: client)
    store.configs = [originalConfig, newlySelectedConfig]
    store.selectedConfigID = newlySelectedConfig.instance_id
    store.instances = [originalInstance]

    await store.restartSelectedConfig(
        replacing: originalInstance,
        configID: originalConfig.instance_id
    )

    #expect(client.stoppedInstanceNames == [[originalConfig.network_name]])
    #expect(client.runConfigs.map(\.instance_id) == [originalConfig.instance_id])
}

@MainActor
@Test func applyConfigDraftSavesStoppedNetworkWithoutStartingIt() async {
    let client = RecordingToggleClient()
    let secrets = MemoryNetworkSecretStore(secrets: ["before": "saved-secret"])
    let original = NetworkConfig(instance_id: "auto-save-id", network_name: "before")
    var updated = original
    updated.network_name = "after"
    let store = EasyTierAppStore(client: client, networkSecretStore: secrets)
    store.configs = [original]

    let result = await store.applyConfigDraft(
        configID: original.instance_id,
        draft: updated,
        replacing: nil
    )

    #expect(result == .saved)
    #expect(store.configs.first?.network_name == "after")
    #expect(client.stoppedInstanceNames.isEmpty)
    #expect(client.runConfigs.isEmpty)
    #expect(secrets.savePurposes.isEmpty)
}

@MainActor
@Test func applyConfigDraftNeverPersistsASecretEmbeddedInTheConfiguration() async {
    let secrets = MemoryNetworkSecretStore()
    let original = NetworkConfig(instance_id: "transient-save-id", network_name: "office")
    var updated = original
    updated.network_secret = "typed-secret"
    let store = EasyTierAppStore(
        client: RecordingToggleClient(),
        networkSecretStore: secrets
    )
    store.configs = [original]

    let result = await store.applyConfigDraft(
        configID: original.instance_id,
        draft: updated,
        replacing: nil
    )

    #expect(result == .saved)
    #expect(store.configs.first?.network_secret?.nilIfEmpty == nil)
    #expect(secrets.savePurposes.isEmpty)
    #expect(secrets.secrets.isEmpty)
}

@MainActor
@Test func unrelatedConfigurationEditDoesNotWriteTheNetworkSecret() async {
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "saved-secret"])
    let original = NetworkConfig(instance_id: "unrelated-edit-id", network_name: "office")
    var updated = original
    updated.hostname = "updated-host"
    let store = EasyTierAppStore(
        client: RecordingToggleClient(),
        networkSecretStore: secrets
    )
    store.configs = [original]

    let result = await store.applyConfigDraft(
        configID: original.id,
        draft: updated,
        replacing: nil
    )

    #expect(result == .saved)
    #expect(store.configs.first?.hostname == "updated-host")
    #expect(secrets.savePurposes.isEmpty)
    #expect(secrets.readPurposes.isEmpty)
}

@MainActor
@Test func applyConfigDraftRestartUsesTheSavedSecretWithoutPersistingAnEmbeddedDraft() async {
    let client = RecordingToggleClient()
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "saved-secret"])
    let original = NetworkConfig(instance_id: "transient-restart-id", network_name: "office")
    var updated = original
    updated.hostname = "updated-host"
    updated.network_secret = "typed-secret"
    let running = NetworkInstance(
        instance_id: original.instance_id,
        name: original.network_name,
        running: true
    )
    let store = EasyTierAppStore(client: client, networkSecretStore: secrets)
    store.configs = [original]
    store.instances = [running]

    let result = await store.applyConfigDraft(
        configID: original.instance_id,
        draft: updated,
        replacing: running
    )

    #expect(result == .restarted)
    #expect(client.runConfigs.first?.network_secret == "saved-secret")
    #expect(secrets.savePurposes.isEmpty)
    #expect(secrets.readPurposes == [.restart])
    #expect(secrets.secrets["office"] == "saved-secret")
}

@MainActor
@Test func stopWithAnEditedSecretDraftDoesNotAccessKeychain() async {
    let client = RecordingToggleClient()
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "saved-secret"])
    let original = NetworkConfig(instance_id: "stop-secret-draft-id", network_name: "office")
    var updated = original
    updated.hostname = "updated-host"
    updated.network_secret = "typed-secret"
    let running = NetworkInstance(
        instance_id: original.instance_id,
        name: original.network_name,
        running: true
    )
    let store = EasyTierAppStore(client: client, networkSecretStore: secrets)
    store.configs = [original]
    store.selectedConfigID = original.id
    store.instances = [running]

    await store.stopSelectedConfig()
    let result = await store.applyConfigDraft(
        configID: original.id,
        draft: updated,
        replacing: nil
    )

    #expect(result == .saved)
    #expect(client.stoppedInstanceNames == [[original.network_name]])
    #expect(store.configs.first?.hostname == "updated-host")
    #expect(secrets.savePurposes.isEmpty)
    #expect(secrets.readPurposes.isEmpty)
    #expect(secrets.deletedIDs.isEmpty)
    #expect(secrets.deletePurposes.isEmpty)
    #expect(secrets.authenticationPurposes.isEmpty)
    #expect(secrets.presenceCallCount == 0)
}

@MainActor
@Test func applyConfigDraftRestartsCapturedRunningInstance() async {
    let client = RecordingToggleClient()
    let original = NetworkConfig(instance_id: "auto-restart-id", network_name: "before")
    var updated = original
    updated.hostname = "after-host"
    let running = NetworkInstance(
        instance_id: original.instance_id,
        name: original.network_name,
        running: true
    )
    let store = EasyTierAppStore(client: client)
    store.configs = [original]
    store.instances = [running]

    let result = await store.applyConfigDraft(
        configID: original.instance_id,
        draft: updated,
        replacing: running
    )

    #expect(result == .restarted)
    #expect(client.stoppedInstanceNames == [[original.network_name]])
    #expect(client.runConfigs.first?.hostname == "after-host")
}

@MainActor
@Test func applyConfigDraftReturnsInlineFailureWithoutPresentingAGlobalError() async {
    let client = RecordingToggleClient()
    client.runError = EasyTierCoreError.operationFailed("automatic restart failed")
    let config = NetworkConfig(instance_id: "auto-failure-id", network_name: "auto-failure")
    let running = NetworkInstance(
        instance_id: config.instance_id,
        name: config.network_name,
        running: true
    )
    let store = EasyTierAppStore(client: client)
    store.configs = [config]
    store.instances = [running]

    let result = await store.applyConfigDraft(
        configID: config.instance_id,
        draft: config,
        replacing: running
    )

    #expect(result == .failed("automatic restart failed"))
    #expect(store.lastError == nil)
}

@MainActor
@Test func applyRemoteConfigChangesValidatesRestartsAndConfirmsTheRemoteConfig() async throws {
    let client = RecordingToggleClient()
    let instanceID = "11111111-2222-3333-4444-555555555555"
    let original = NetworkConfig(instance_id: instanceID, hostname: "before-host")
    var updated = original
    updated.hostname = "after-host"

    let configObject = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(updated)) as? [String: Any]
    )
    let responseData = try JSONSerialization.data(withJSONObject: ["config": configObject])
    client.jsonRPCResponsesByMethod["get_config"] = String(decoding: responseData, as: UTF8.self)

    let member = NetworkMemberStatus(
        id: "remote-peer",
        isLocal: false,
        peerID: "42",
        instanceID: instanceID,
        virtualIPv4: "10.126.126.9/24",
        hostname: "remote-mac",
        version: "2.6.4",
        routeCost: "P2P",
        tunnelProto: "tcp",
        latency: "12 ms",
        uploadTotal: "1 KiB",
        downloadTotal: "2 KiB",
        lossRate: "0%",
        natType: "Open Internet",
        isPublicServer: false,
        txBytes: 1_024,
        rxBytes: 2_048
    )
    let store = EasyTierAppStore(client: client)
    store.remoteConfigSession = RemoteConfigSession(
        rpcURL: try #require(URL(string: "tcp://10.126.126.9:15888")),
        instanceID: instanceID,
        member: member,
        config: updated,
        originalConfig: original,
        isLoading: false,
        loadError: nil
    )

    let success = await store.applyRemoteConfigChanges()

    #expect(success)
    #expect(store.remoteConfigSession?.originalConfig == updated)
    #expect(store.remoteConfigSession?.originalConfigPayload != nil)
    #expect(store.remoteConfigSession?.applyState == .applied)
    #expect(client.jsonRPCCalls.map(\.method) == ["validate_config", "run_network_instance", "get_config"])
}

@MainActor
@Test func longSystemSleepRestartsPreviouslyRunningConfig() async throws {
    let client = RecordingToggleClient()
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "wake-secret"])
    let config = NetworkConfig(instance_id: "wake-id", network_name: "office", network_secret: nil)
    let store = EasyTierAppStore(client: client, networkSecretStore: secrets)

    store.configs = [config]
    store.selectedConfigID = config.instance_id
    let readyDetail = NetworkInstanceRunningInfo(
        my_node_info: NodeInfo(ipv4_addr: "10.0.64.1/24", hostname: "local", peer_id: 7),
        running: true,
        instance_id: config.instance_id
    )
    store.instances = [
        NetworkInstance(
            instance_id: config.instance_id,
            name: config.network_name,
            running: true,
            detail: readyDetail
        ),
    ]
    store.runtimeDetails = [config.network_name: readyDetail]
    client.networkInfos = [
        config.network_name: readyDetail,
    ]

    store.handleSystemWillSleep(now: Date(timeIntervalSince1970: 100))
    await store.handleSystemDidWake(now: Date(timeIntervalSince1970: 160))

    #expect(client.stoppedInstanceNames == [[config.network_name]])
    #expect(client.runConfigs.map(\.instance_id) == [config.instance_id])
    #expect(client.runConfigs.first?.network_secret == "wake-secret")
}

@MainActor
@Test func longSystemSleepDoesNotRestartStartingConfig() async {
    let client = RecordingToggleClient()
    let config = NetworkConfig(instance_id: "starting-wake-id", network_name: "starting-office")
    let store = EasyTierAppStore(client: client)

    store.configs = [config]
    store.selectedConfigID = config.instance_id
    store.instances = [
        NetworkInstance(
            instance_id: config.instance_id,
            name: config.network_name,
            running: true,
            detail: NetworkInstanceRunningInfo(running: true, instance_id: config.instance_id)
        ),
    ]

    store.handleSystemWillSleep(now: Date(timeIntervalSince1970: 100))
    await store.handleSystemDidWake(now: Date(timeIntervalSince1970: 160))

    #expect(client.stoppedInstanceNames.isEmpty)
    #expect(client.runConfigs.isEmpty)
}

@MainActor
@Test func shortSystemSleepOnlyRefreshesRuntime() async throws {
    let client = RecordingToggleClient()
    let config = NetworkConfig(instance_id: "short-wake-id", network_name: "office")
    let store = EasyTierAppStore(client: client)

    store.configs = [config]
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
@Test func exportSelectedTOMLIsRedactedByDefaultWithoutReadingKeychain() async throws {
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "export-secret"])
    let config = NetworkConfig(instance_id: "redacted-export-id", network_name: "office")
    let store = EasyTierAppStore(
        client: RecordingToggleClient(),
        networkSecretStore: secrets
    )
    store.configs = [config]
    store.selectedConfigID = config.instance_id

    let toml = try await store.exportSelectedTOML()

    #expect(!toml.contains("network_secret"))
    #expect(!toml.contains("export-secret"))
    #expect(secrets.readReasons.isEmpty)
}

@MainActor
@Test func exportSelectedTOMLUsesKeychainNetworkSecret() async throws {
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "export-secret"])
    let config = NetworkConfig(instance_id: "export-id", network_name: "office", network_secret: nil)
    let store = EasyTierAppStore(
        client: RecordingToggleClient(),
        networkSecretStore: secrets
    )

    store.configs = [config]
    store.selectedConfigID = config.instance_id

    let toml = try await store.exportSelectedTOML(
        options: TOMLExportOptions(includeNetworkSecret: true)
    )

    #expect(toml.contains("export-secret"))
}

@MainActor
@Test func applicationFocusLossDoesNotStripAnInFlightPlaintextExport() async throws {
    let secrets = BlockingNetworkSecretStore(secret: "export-secret")
    let config = NetworkConfig(instance_id: "focus-loss-export-id", network_name: "office")
    let store = EasyTierAppStore(
        client: RecordingToggleClient(),
        networkSecretStore: secrets
    )
    store.configs = [config]
    store.selectedConfigID = config.id

    let exportTask = Task {
        try await store.exportSelectedTOML(
            options: TOMLExportOptions(includeNetworkSecret: true)
        )
    }
    defer { secrets.releaseReads() }

    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while secrets.readCount == 0, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(secrets.readCount == 1)

    store.handleApplicationDidResignActive()
    #expect(secrets.authenticationInvalidationCount == 0)
    secrets.releaseReads()

    let toml = try await exportTask.value
    #expect(toml.contains("network_secret = \"export-secret\""))
}

@MainActor
@Test func runtimeCacheNeverBypassesFreshRevealOrPlaintextExport() async throws {
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "saved-secret"])
    let config = NetworkConfig(instance_id: "fresh-secret-action-id", network_name: "office")
    let store = EasyTierAppStore(
        client: RecordingToggleClient(),
        networkSecretStore: secrets
    )
    store.configs = [config]
    store.selectedConfigID = config.id

    await store.runSelectedConfig()
    _ = try await store.revealNetworkSecret(for: config)
    _ = try await store.exportSelectedTOML(
        options: TOMLExportOptions(includeNetworkSecret: true)
    )

    #expect(secrets.readPurposes == [.run, .reveal, .export])
}

@MainActor
@Test func exportSelectedTOMLPrefersTransientSecretWithoutReadingKeychain() async throws {
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "saved-secret"])
    let config = NetworkConfig(instance_id: "transient-export-id", network_name: "office")
    let store = EasyTierAppStore(
        client: RecordingToggleClient(),
        networkSecretStore: secrets
    )

    store.configs = [config]
    store.selectedConfigID = config.instance_id

    let toml = try await store.exportSelectedTOML(
        options: TOMLExportOptions(includeNetworkSecret: true),
        networkSecretInput: .edited("typed-secret")
    )

    #expect(toml.contains("network_secret = \"typed-secret\""))
    #expect(!toml.contains("saved-secret"))
    #expect(secrets.readReasons.isEmpty)
    #expect(secrets.authenticationPurposes == [.export])
}

@MainActor
@Test func exportSelectedTOMLAppliesMagicDNSSettingsOverlay() async throws {
    var config = NetworkConfig(instance_id: "dns-export-id", network_name: "office")
    config.enable_magic_dns = true
    let store = EasyTierAppStore(client: RecordingToggleClient())
    store.configs = [config]
    store.selectedConfigID = config.instance_id
    store.magicDNSSettings = try MagicDNSSettings(dnsSuffix: "lab.internal")

    let toml = try await store.exportSelectedTOML()

    #expect(toml.contains("accept_dns = true"))
    #expect(toml.contains("tld_dns_zone = \"lab.internal.\""))
}

@MainActor
@Test func runSelectedConfigAppliesMagicDNSSettingsOverlay() async throws {
    let client = RecordingToggleClient()
    var config = NetworkConfig(instance_id: "dns-run-id", network_name: "office")
    config.enable_magic_dns = true
    config.no_tun = true
    let store = EasyTierAppStore(client: client)
    store.configs = [config]
    store.selectedConfigID = config.instance_id
    store.magicDNSSettings = try MagicDNSSettings(dnsSuffix: "lab.internal")

    await store.runSelectedConfig()

    #expect(client.runTOMLs.first?.contains("tld_dns_zone = \"lab.internal.\"") == true)
}

@MainActor
@Test func importTOMLPromotesMagicDNSSuffixToAppSettings() async throws {
    var config = NetworkConfig(instance_id: "dns-import-id", network_name: "office")
    config.enable_magic_dns = true
    let toml = try NetworkConfigTOMLCodec.encode(
        config,
        magicDNSSettings: try MagicDNSSettings(dnsSuffix: "imported.internal")
    )
    let store = EasyTierAppStore()

    await store.importTOML(toml)

    #expect(store.magicDNSSettings.dnsSuffix == "imported.internal.")
    #expect(store.configs.first?.enable_magic_dns == true)
    #expect(store.configs.count == 1)
}

@MainActor
@Test func changingMagicDNSSuffixRecordsRestartNoticeForRunningMagicDNSNetwork() async throws {
    let client = RecordingToggleClient()
    var config = NetworkConfig(instance_id: "dns-notice-id", network_name: "office")
    config.enable_magic_dns = true
    let store = EasyTierAppStore(client: client)
    store.configs = [config]
    store.instances = [NetworkInstance(instance_id: config.instance_id, name: config.network_name, running: true)]

    await store.applyMode(.default, magicDNSSettings: try MagicDNSSettings(dnsSuffix: "lab.internal"))

    #expect(store.logLines.contains { $0.text.contains("Magic DNS suffix changed") && $0.text.contains("Restart office") })
}

@MainActor
@Test func magicDNSResolverIsActiveOnlyForRunningEnabledNetworks() {
    var magicDNSConfig = NetworkConfig(instance_id: "magic-dns", network_name: "magic")
    magicDNSConfig.enable_magic_dns = true
    let plainConfig = NetworkConfig(instance_id: "plain", network_name: "plain")
    let store = EasyTierAppStore(client: RecordingToggleClient())
    store.configs = [magicDNSConfig, plainConfig]

    #expect(!store.isMagicDNSResolverActive)

    store.instances = [
        NetworkInstance(instance_id: plainConfig.instance_id, name: plainConfig.network_name, running: true),
    ]
    #expect(!store.isMagicDNSResolverActive)

    store.instances.append(
        NetworkInstance(instance_id: magicDNSConfig.instance_id, name: magicDNSConfig.network_name, running: true)
    )
    #expect(store.isMagicDNSResolverActive)

    store.instances.removeAll { $0.instance_id == magicDNSConfig.instance_id }
    #expect(!store.isMagicDNSResolverActive)
}

@Test func storagePersistsMagicDNSSettingsInSnapshotOnly() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let storage = EasyTierStorage(baseDirectory: directory)
    var config = NetworkConfig(instance_id: "dns-storage-id", network_name: "office")
    config.enable_magic_dns = true
    let snapshot = AppSnapshot(
        configIDs: [config.id],
        mode: .default,
        lastSelectedConfigID: config.instance_id,
        magicDNSSettings: try MagicDNSSettings(dnsSuffix: "stored.internal")
    )

    try storage.save(snapshot, configs: [config])

    let loaded = try storage.load()
    let tomlURL = directory.appendingPathComponent("configs/dns-storage-id.toml")
    let toml = try String(contentsOf: tomlURL, encoding: .utf8)

    #expect(loaded.snapshot.magicDNSSettings.dnsSuffix == "stored.internal.")
    #expect(!toml.contains("tld_dns_zone"))
}

@MainActor
@Test func explicitNetworkSecretReadReportsErrors() async {
    let config = NetworkConfig(instance_id: "explicit-error-id", network_name: "office")
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "secret"])
    secrets.readError = EasyTierCoreError.operationFailed("keychain failed")
    let store = EasyTierAppStore(
        client: RecordingToggleClient(),
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
@Test func sequentialSecretReadsDoNotRetainAPlaintextAppStoreCache() async {
    let config = NetworkConfig(instance_id: "cache-id", network_name: "office")
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "cached-secret"])
    let store = EasyTierAppStore(
        client: RecordingToggleClient(),
        networkSecretStore: secrets
    )

    _ = try? await store.revealNetworkSecret(for: config)
    #expect(secrets.readReasons.count == 1)

    _ = try? await store.revealNetworkSecret(for: config)
    #expect(secrets.readReasons.count == 2, "LAContext, not the plaintext secret, owns authentication reuse")
}

@MainActor
@Test func concurrentSecretReadsUseIndependentAuthenticationActions() async throws {
    let config = NetworkConfig(instance_id: "concurrent-secret-id", network_name: "office")
    let secrets = BlockingNetworkSecretStore(secret: "shared-secret")
    let store = EasyTierAppStore(
        client: RecordingToggleClient(),
        networkSecretStore: secrets
    )

    let first = Task { try await store.revealNetworkSecret(for: config) }
    let second = Task { try await store.revealNetworkSecret(for: config) }
    defer { secrets.releaseReads() }

    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while secrets.readCount < 2, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
    try? await Task.sleep(for: .milliseconds(50))

    #expect(secrets.readCount == 2, "each user action must own its own Keychain authentication")

    secrets.releaseReads()
    #expect(try await first.value == "shared-secret")
    #expect(try await second.value == "shared-secret")
}

@MainActor
@Test func systemSleepInvalidatesNetworkSecretAuthenticationSession() {
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "secret"])
    let store = EasyTierAppStore(
        client: RecordingToggleClient(),
        networkSecretStore: secrets
    )

    store.handleSystemWillSleep(now: Date(timeIntervalSince1970: 100))

    #expect(secrets.authenticationInvalidationCount == 1)
    #expect(store.networkSecretSessionRevision == 1)
}

@MainActor
@Test func selectingAnotherNetworkInvalidatesNetworkSecretSession() {
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "secret"])
    let first = NetworkConfig(instance_id: "first-secret-session-id", network_name: "office")
    let second = NetworkConfig(instance_id: "second-secret-session-id", network_name: "lab")
    let store = EasyTierAppStore(
        client: RecordingToggleClient(),
        networkSecretStore: secrets
    )
    store.configs = [first, second]

    store.selectedConfigID = first.instance_id
    #expect(store.networkSecretSessionRevision == 0)

    store.selectedConfigID = second.instance_id

    #expect(secrets.authenticationInvalidationCount == 1)
    #expect(store.networkSecretSessionRevision == 1)
}

@MainActor
@Test func workspaceSessionResignInvalidatesNetworkSecretAuthenticationSession() {
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "secret"])
    let store = EasyTierAppStore(
        client: RecordingToggleClient(),
        networkSecretStore: secrets
    )

    store.handleUserSessionDidResignActive()

    #expect(secrets.authenticationInvalidationCount == 1)
    #expect(store.networkSecretSessionRevision == 1)
}

@MainActor
@Test func canceledNetworkSecretReadDoesNotSurfaceGlobalError() async {
    let config = NetworkConfig(instance_id: "canceled-secret-id", network_name: "office")
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "secret"])
    secrets.readError = NetworkSecretStoreError.keychain(errSecUserCanceled)
    let store = EasyTierAppStore(
        client: RecordingToggleClient(),
        networkSecretStore: secrets
    )
    store.configs = [config]
    store.selectedConfigID = config.instance_id

    await store.runSelectedConfig()

    #expect(store.lastError == nil)
}

@MainActor
@Test func applicationFocusLossPreservesAuthenticationAndDraftRevision() {
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "secret"])
    let store = EasyTierAppStore(
        client: RecordingToggleClient(),
        networkSecretStore: secrets
    )

    store.handleApplicationDidResignActive()

    #expect(secrets.authenticationInvalidationCount == 0)
    #expect(store.networkSecretSessionRevision == 0)
}

@MainActor
@Test func wakeRecoveryWaitsUntilTheApplicationIsActive() async {
    let client = RecordingToggleClient()
    let controller = RuntimeSessionController(
        privilegedClient: client,
        inProcessClient: client,
        helperRegistration: nil,
        systemSleepPreventer: RecordingSystemSleepPreventer(),
        wakeRecoveryDelay: .milliseconds(10)
    )
    var recoveryCount = 0
    controller.startPolling(
        refresh: {},
        handleWillSleep: {},
        handleSessionResign: {},
        handleDidWake: { recoveryCount += 1 }
    )
    defer { controller.stopPolling() }

    controller.setApplicationActive(false)
    controller.handleSystemDidWakeNotification()
    try? await Task.sleep(for: .milliseconds(30))
    #expect(recoveryCount == 0)

    controller.setApplicationActive(true)
    try? await Task.sleep(for: .milliseconds(30))
    #expect(recoveryCount == 1)
}

@MainActor
@Test func wakeRecoveryWaitsUntilTheUserSessionIsActive() async {
    let client = RecordingToggleClient()
    let controller = RuntimeSessionController(
        privilegedClient: client,
        inProcessClient: client,
        helperRegistration: nil,
        systemSleepPreventer: RecordingSystemSleepPreventer(),
        wakeRecoveryDelay: .milliseconds(10)
    )
    var recoveryCount = 0
    controller.startPolling(
        refresh: {},
        handleWillSleep: {},
        handleSessionResign: {},
        handleDidWake: { recoveryCount += 1 }
    )
    defer { controller.stopPolling() }

    controller.handleUserSessionDidResignActiveNotification()
    controller.handleSystemDidWakeNotification()
    try? await Task.sleep(for: .milliseconds(30))
    #expect(recoveryCount == 0)

    controller.handleUserSessionDidBecomeActiveNotification()
    try? await Task.sleep(for: .milliseconds(30))
    #expect(recoveryCount == 1)
}

@MainActor
@Test func importTOMLMigratesNetworkSecretToKeychain() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let storage = EasyTierStorage(baseDirectory: directory)
    let secrets = MemoryNetworkSecretStore()
    let config = NetworkConfig(instance_id: "import-id", network_name: "office", network_secret: "import-secret")
    let store = EasyTierAppStore(
        client: RecordingToggleClient(),
        storage: storage,
        networkSecretStore: secrets
    )

    await store.importTOML(try NetworkConfigTOMLCodec.encode(config))

    let toml = try String(contentsOf: directory.appendingPathComponent("configs/import-id.toml"), encoding: .utf8)

    #expect(secrets.secrets["office"] == "import-secret")
    #expect(!toml.contains("import-secret"))
    #expect(store.configs.first?.network_secret?.nilIfEmpty == nil)
}

@MainActor
@Test func importTOMLSurfacesReadableParserErrors() async {
    let store = EasyTierAppStore()

    await store.importTOML(#"instance_name = "broken"#)

    #expect(store.lastError?.contains("Invalid TOML syntax at line") == true)
}

@MainActor
@Test func importTOMLReportsInvalidCharacterAtParserErrorLocation() async {
    let store = EasyTierAppStore()

    await store.importTOML("instance_name = \u{201C}broken\"")

    #expect(store.lastError?.contains("Character at line 1, column 17") == true)
    #expect(store.lastError?.contains("U+201C") == true)
}

@MainActor
@Test func deleteSelectedConfigRemovesTheLastSharedKeychainSecret() async {
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "secret"])
    let config = NetworkConfig(instance_id: "delete-id", network_name: "office")
    let store = EasyTierAppStore(client: RecordingToggleClient(), networkSecretStore: secrets)

    store.configs = [config]
    store.selectedConfigID = config.instance_id

    await store.deleteSelectedConfig()

    #expect(secrets.secrets["office"] == nil)
}

@MainActor
@Test func deleteSelectedConfigKeepsASecretReferencedByAnotherConfig() async {
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "secret"])
    let first = NetworkConfig(instance_id: "delete-shared-first", network_name: "office")
    let second = NetworkConfig(instance_id: "delete-shared-second", network_name: "office")
    let store = EasyTierAppStore(client: RecordingToggleClient(), networkSecretStore: secrets)
    store.configs = [first, second]
    store.selectedConfigID = first.instance_id

    await store.deleteSelectedConfig()

    #expect(secrets.secrets["office"] == "secret")
    #expect(store.configs.map(\.id) == [second.id])
}

@MainActor
@Test func canceledKeychainAuthorizationLeavesTheNetworkWithoutShowingAnError() async {
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "secret"])
    secrets.deleteError = NetworkSecretStoreError.authentication(LAError.Code.appCancel.rawValue)
    let config = NetworkConfig(instance_id: "delete-app-cancel-id", network_name: "office")
    let store = EasyTierAppStore(
        client: RecordingToggleClient(),
        networkSecretStore: secrets
    )
    store.configs = [config]
    store.selectedConfigID = config.id

    await store.deleteSelectedConfig()

    #expect(store.configs == [config])
    #expect(store.selectedConfigID == config.id)
    #expect(store.lastError == nil)
}

@MainActor
@Test func keychainNetworkSecretsAreScopedByNetworkName() async throws {
    let secrets = MemoryNetworkSecretStore()
    let first = NetworkConfig(instance_id: "first-id", network_name: "office", network_secret: "office-secret")
    let second = NetworkConfig(instance_id: "second-id", network_name: "lab", network_secret: "lab-secret")
    let store = EasyTierAppStore(
        client: RecordingToggleClient(),
        networkSecretStore: secrets
    )

    try await store.saveNetworkSecretToKeychain("office-secret", for: first)
    try await store.saveNetworkSecretToKeychain("lab-secret", for: second)
    store.configs = [first, second].map {
        var config = $0
        config.network_secret = nil
        return config
    }
    store.save()

    #expect(secrets.secrets["office"] == "office-secret")
    #expect(secrets.secrets["lab"] == "lab-secret")
}

@MainActor
@Test func updateConfigMigratesKeychainSecretWhenNetworkNameChanges() async throws {
    let secrets = MemoryNetworkSecretStore(secrets: ["office": "office-secret"])
    let original = NetworkConfig(instance_id: "rename-id", network_name: "office")
    let store = EasyTierAppStore(
        client: RecordingToggleClient(),
        networkSecretStore: secrets
    )

    store.configs = [original]
    store.selectedConfigID = original.instance_id

    var updated = original
    updated.network_name = "renamed"
    try await store.updateConfig(id: original.instance_id, with: updated, saveImmediately: true)

    #expect(secrets.secrets["renamed"] == "office-secret")
    #expect(secrets.secrets["office"] == nil)
}

@Test func incompatibleStateIsBackedUpAndTomlFilesArePreserved() throws {
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

    #expect(loaded.recoveryMessage?.contains("re-import") == true)
    #expect(loaded.configs.count == 1)
    #expect(loaded.configs.first?.instance_id != config.instance_id)
    #expect(FileManager.default.fileExists(atPath: configURL.path))
    let backupNames = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(backupNames.contains { $0.hasPrefix("state.incompatible-") && $0.hasSuffix(".json") })
}

@Test func currentSchemaConfigFailureDoesNotResetState() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let storage = EasyTierStorage(baseDirectory: directory)
    let config = NetworkConfig(instance_id: "current-id", network_name: "current")
    let snapshot = AppSnapshot(configIDs: [config.id], lastSelectedConfigID: config.id)
    try storage.save(snapshot, configs: [config])

    let stateURL = directory.appendingPathComponent("state.json")
    let originalState = try Data(contentsOf: stateURL)
    try "invalid = [".write(to: storage.configURL(forID: config.id), atomically: true, encoding: .utf8)

    do {
        _ = try storage.load()
        Issue.record("A current-schema state with invalid TOML should surface the config error.")
    } catch {}

    #expect(try Data(contentsOf: stateURL) == originalState)
    let backupNames = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(!backupNames.contains { $0.hasPrefix("state.incompatible-") && $0.hasSuffix(".json") })
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
        desiredHostname: "new-host",
        baseHostname: "old-host",
        status: .pending
    )
    let snapshot = AppSnapshot(
        configIDs: [config.id],
        mode: .default,
        lastSelectedConfigID: config.instance_id,
        runtimeIntents: [intent]
    )

    try storage.save(snapshot, configs: [config])
    let loaded = try storage.load()

    #expect(loaded.snapshot.runtimeIntents.count == 1)
    #expect(loaded.snapshot.runtimeIntents.first?.target.instanceID == "remote-id")
    #expect(loaded.snapshot.runtimeIntents.first?.desiredHostname == "new-host")
    #expect(loaded.snapshot.runtimeIntents.first?.baseHostname == "old-host")
    #expect(loaded.snapshot.runtimeIntents.first?.status == .pending)
}

@Test func defaultStorageUsesBundleSpecificAppSupportDirectory() {
    #expect(EasyTierStorage.default.baseDirectory.lastPathComponent == "com.kkrainbow.easytier.mac")
}

@Test func testStoreStorageIsIsolatedFromApplicationSupport() {
    let storage = EasyTierStorage.isolatedForTesting()

    #expect(storage.baseDirectory.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    #expect(storage.baseDirectory.lastPathComponent != "com.kkrainbow.easytier.mac")
}

@MainActor
@Test func selectedConfigDoesNotFallBackToFirstConfigWhenSelectionIsCleared() {
    let first = NetworkConfig(instance_id: "first-id", network_name: "first-network")
    let second = NetworkConfig(instance_id: "second-id", network_name: "second-network")
    let store = EasyTierAppStore(client: RecordingToggleClient())

    store.configs = [first, second]
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
    let store = EasyTierAppStore(client: RecordingToggleClient(), storage: storage)

    store.configs = [first, second]
    store.selectedConfigID = first.instance_id

    store.selectNextConfig()

    #expect(store.selectedConfigID == second.instance_id)
    #expect(try storage.load().snapshot.lastSelectedConfigID == second.instance_id)

    store.selectNextConfig()

    #expect(store.selectedConfigID == first.instance_id)
}

@MainActor
@Test func selectPreviousConfigWrapsToLastConfig() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let storage = EasyTierStorage(baseDirectory: directory)
    let first = NetworkConfig(instance_id: "first-id", network_name: "first-network")
    let second = NetworkConfig(instance_id: "second-id", network_name: "second-network")
    let store = EasyTierAppStore(client: RecordingToggleClient(), storage: storage)

    store.configs = [first, second]
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
    let store = EasyTierAppStore(client: RecordingToggleClient(), storage: storage)

    store.configs = [first, second]
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
    let snapshot = AppSnapshot(configIDs: [config.id], mode: .default, lastSelectedConfigID: "missing-id")
    try storage.save(snapshot, configs: [config])

    let store = EasyTierAppStore(client: RecordingToggleClient(), storage: storage)

    await store.load()
    store.stopPolling()

    #expect(store.selectedConfigID == config.instance_id)
    #expect(store.selectedConfig?.network_name == config.network_name)
}

@MainActor
@Test func loadKeepsSavedEmptyConfigList() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let storage = EasyTierStorage(baseDirectory: directory)
    try storage.save(AppSnapshot(configIDs: [], mode: .default, lastSelectedConfigID: nil), configs: [])

    let store = EasyTierAppStore(client: RecordingToggleClient(), storage: storage)

    await store.load()
    store.stopPolling()

    #expect(store.configs.isEmpty)
    #expect(store.selectedConfigID == nil)
}

@MainActor
@Test func runtimePollingContinuesWhileAViewIsScrolling() async {
    let client = BlockingRuntimeMutationClient()
    let store = EasyTierAppStore(client: client)
    store.isAnyViewScrolling = true

    store.startPolling()
    defer { store.stopPolling() }

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(3))
    var counts = await client.counts()
    while counts.collects == 0, clock.now < deadline {
        try? await Task.sleep(for: .milliseconds(50))
        counts = await client.counts()
    }
    #expect(counts.collects >= 1)
}

@MainActor
@Test func applyModeConfiguresRPCPortal() async throws {
    let client = RecordingToggleClient()
    let store = EasyTierAppStore(client: client)

    await store.applyMode(AppMode(
        rpcListenEnabled: true,
        rpcListenPort: 15_998,
        rpcPortalWhitelist: ["127.0.0.0/8", "10.126.126.0/24"]
    ))
    await store.applyMode(AppMode(
        rpcListenEnabled: false,
        rpcListenPort: 15_998,
        rpcPortalWhitelist: ["127.0.0.0/8"]
    ))

    #expect(client.configuredRPCPortals == ["tcp://0.0.0.0:15998", nil])
    #expect(client.configuredRPCPortalWhitelists == [["127.0.0.0/8", "10.126.126.0/24"], ["127.0.0.0/8"]])
}

@MainActor
@Test func selectedRunningInstanceDoesNotFallBackToFirstInstance() {
    let first = NetworkConfig(instance_id: "first-id", network_name: "first-network")
    let second = NetworkConfig(instance_id: "second-id", network_name: "second-network")
    let store = EasyTierAppStore(client: RecordingToggleClient())

    store.configs = [first, second]
    store.selectedConfigID = second.instance_id
    store.instances = [NetworkInstance(instance_id: first.instance_id, name: first.network_name, running: true)]

    #expect(store.selectedRunningInstance == nil)
    #expect(store.selectedMemberStatuses.isEmpty)
}

@MainActor
@Test func selectedRunningInstancePrefersInstanceIDWhenNamesMatch() throws {
    let first = NetworkConfig(instance_id: "first-id", network_name: "shared-network")
    let second = NetworkConfig(instance_id: "second-id", network_name: "shared-network")
    let store = EasyTierAppStore(client: RecordingToggleClient())

    store.configs = [first, second]
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
    let store = EasyTierAppStore(client: RecordingToggleClient())

    store.configs = [config]
    store.selectedConfigID = config.instance_id
    store.instances = [NetworkInstance(instance_id: config.network_name, name: config.network_name, running: true)]

    let selected = try #require(store.selectedRunningInstance)
    #expect(selected.instance_id == config.network_name)
}

@MainActor
@Test func restartSelectedConfigStopsOldRuntimeNameBeforeRunningUpdatedConfig() async throws {
    let original = NetworkConfig(instance_id: "config-id", network_name: "old-network")
    var updated = original
    updated.network_name = "new-network"
    let client = RecordingToggleClient()
    let store = EasyTierAppStore(client: client)
    let runningInstance = NetworkInstance(instance_id: original.network_name, name: original.network_name, running: true)

    store.configs = [original]
    store.selectedConfigID = original.instance_id
    store.instances = [runningInstance]
    try await store.updateConfig(id: original.instance_id, with: updated)

    await store.restartSelectedConfig(replacing: runningInstance)

    #expect(client.stoppedInstanceNames == [[original.network_name]])
    #expect(client.runConfigs.map(\.network_name) == [updated.network_name])
}

@MainActor
@Test func selectedRunningInstanceDoesNotUseAmbiguousNameFallback() {
    let first = NetworkConfig(instance_id: "first-id", network_name: "shared-network")
    let second = NetworkConfig(instance_id: "second-id", network_name: "shared-network")
    let store = EasyTierAppStore(client: RecordingToggleClient())

    store.configs = [first, second]
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

    store.configs = [first, second]
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

    store.configs = [first, second]
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

    store.configs = [config]
    store.selectedConfigID = config.instance_id
    store.instances = [NetworkInstance(
        instance_id: config.instance_id,
        name: config.network_name,
        running: true,
        detail: NetworkInstanceRunningInfo(my_node_info: NodeInfo(hostname: "new-host"))
    )]

    await store.stopSelectedConfig()

    #expect(store.configs.first?.hostname == "new-host")
    #expect(try storage.load().configs.first?.hostname == "new-host")
    #expect(client.stoppedInstanceNames == [[config.network_name]])
}

@MainActor
@Test func runtimeIntentReplaysHostnameWhenRuntimeReturnedToBase() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let client = RecordingToggleClient()
    let store = EasyTierAppStore(client: client, storage: EasyTierStorage(baseDirectory: directory))
    let config = NetworkConfig(instance_id: "11111111-1111-1111-1111-111111111111", network_name: "office")
    store.configs = [config]
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
    store.configs = [config]
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
    store.configs = [config]
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
    store.configs = [config]
    store.selectedConfigID = config.instance_id
    var updated = config
    updated.hostname = "desired"
    try await store.updateConfig(id: config.instance_id, with: updated, saveImmediately: true)
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
    #expect(try storage.load().configs.first?.hostname == "desired")
}

@MainActor
@Test func runSelectedConfigReportsRunningPortConflictBeforeStarting() async {
    var running = NetworkConfig(instance_id: "running-id", network_name: "running")
    running.listener_urls = ["tcp://0.0.0.0:11010"]
    var selected = NetworkConfig(instance_id: "selected-id", network_name: "selected")
    selected.listener_urls = ["tcp://127.0.0.1:11010"]
    let client = RecordingToggleClient()
    let store = EasyTierAppStore(client: client)

    store.configs = [running, selected]
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

    store.configs = [config]
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

    store.configs = [config]
    store.selectedConfigID = config.instance_id

    await store.deleteSelectedConfig()

    #expect(store.configs.isEmpty)
    #expect(store.selectedConfigID == nil)
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
@Test func runSelectedConfigKeepsPendingInstanceStartingWhenRuntimeListIsInitiallyEmpty() async throws {
    let client = PendingStartClient()
    let config = NetworkConfig(instance_id: "pending-id", network_name: "pending-network")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = EasyTierAppStore(client: client, storage: EasyTierStorage(baseDirectory: directory))

    store.configs = [config]
    store.selectedConfigID = config.instance_id

    await store.runSelectedConfig()

    let selected = try #require(store.selectedRunningInstance)
    #expect(client.didRun)
    #expect(selected.instance_id == config.instance_id)
    #expect(selected.name == config.network_name)
    #expect(selected.running)
    #expect(selected.detail?.running == true)
    #expect(store.selectedConfigCanStop)
    #expect(store.selectedConfigIsRunning)
    #expect(!store.selectedConfigIsReady)
    #expect(store.selectedRuntimeReadinessPhase == .starting)
    #expect(store.lastError == nil)
}

@MainActor
@Test func runtimeSessionControllerKeepsPendingStartUntilRuntimeAppears() async throws {
    let client = RecordingToggleClient()
    let sleepPreventer = RecordingSystemSleepPreventer()
    let controller = RuntimeSessionController(
        privilegedClient: client,
        inProcessClient: client,
        helperRegistration: nil,
        systemSleepPreventer: sleepPreventer
    )
    let config = NetworkConfig(instance_id: "pending-id", network_name: "pending-network")

    controller.recordPendingStart(for: config)
    let pendingResult = try await controller.refreshRuntime(
        currentInstances: [],
        currentRuntimeDetails: [:],
        currentStatusMetrics: [:],
        currentTrafficSamples: [:],
        currentTrafficSamplingStatus: [:],
        selectedTab: .status
    )
    let pendingChange = try #require(pendingResult)

    #expect(pendingChange.state.instances.map(\.instance_id) == [config.instance_id])
    #expect(pendingChange.state.instances.first?.detail?.running == true)
    #expect(pendingChange.state.instances.first?.runtimeReadinessPhase(requiresTUN: true) == .starting)
    #expect(sleepPreventer.isPreventingSystemSleep)

    client.networkInfos = [
        config.network_name: NetworkInstanceRunningInfo(
            my_node_info: NodeInfo(hostname: "local", peer_id: 7),
            running: true,
            instance_id: config.instance_id
        ),
    ]
    let startingRuntimeResult = try await controller.refreshRuntime(
        currentInstances: pendingChange.state.instances,
        currentRuntimeDetails: pendingChange.state.runtimeDetails,
        currentStatusMetrics: pendingChange.state.statusMetricsByInstance,
        currentTrafficSamples: pendingChange.state.trafficSamplesByInstance,
        currentTrafficSamplingStatus: pendingChange.state.trafficSamplingStatusByInstance,
        selectedTab: .status
    )
    let startingRuntimeChange = try #require(startingRuntimeResult)

    #expect(startingRuntimeChange.state.instances.first?.detail?.my_node_info != nil)
    #expect(startingRuntimeChange.state.instances.first?.runtimeReadinessPhase(requiresTUN: true) == .starting)

    client.collectError = EasyTierCoreError.operationFailed("temporary collect failure")
    let failedCollectResult = try await controller.refreshRuntime(
        currentInstances: startingRuntimeChange.state.instances,
        currentRuntimeDetails: startingRuntimeChange.state.runtimeDetails,
        currentStatusMetrics: startingRuntimeChange.state.statusMetricsByInstance,
        currentTrafficSamples: startingRuntimeChange.state.trafficSamplesByInstance,
        currentTrafficSamplingStatus: startingRuntimeChange.state.trafficSamplingStatusByInstance,
        selectedTab: .status
    )
    let failedCollectChange = try #require(failedCollectResult)

    #expect(failedCollectChange.state.instances.map(\.instance_id) == [config.instance_id])
    #expect(failedCollectChange.state.instances.first?.runtimeReadinessPhase(requiresTUN: true) == .starting)
    #expect(sleepPreventer.isPreventingSystemSleep)

    client.collectError = nil
    client.networkInfos = [
        config.network_name: NetworkInstanceRunningInfo(
            my_node_info: NodeInfo(ipv4_addr: "10.0.64.1/24", hostname: "local", peer_id: 7),
            running: true,
            instance_id: config.instance_id
        ),
    ]
    let runningResult = try await controller.refreshRuntime(
        currentInstances: failedCollectChange.state.instances,
        currentRuntimeDetails: failedCollectChange.state.runtimeDetails,
        currentStatusMetrics: failedCollectChange.state.statusMetricsByInstance,
        currentTrafficSamples: failedCollectChange.state.trafficSamplesByInstance,
        currentTrafficSamplingStatus: failedCollectChange.state.trafficSamplingStatusByInstance,
        selectedTab: .status
    )
    let runningChange = try #require(runningResult)

    #expect(runningChange.state.instances.map(\.instance_id) == [config.instance_id])
    #expect(runningChange.state.instances.map(\.name) == [config.network_name])
    #expect(runningChange.state.instances.first?.runtimeReadinessPhase(requiresTUN: true) == .ready)
}

@MainActor
@Test func pendingStartCanBeStoppedWithoutStartingAgain() async {
    let client = RecordingToggleClient()
    let config = NetworkConfig(instance_id: "pending-id", network_name: "pending-network")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = EasyTierAppStore(client: client, storage: EasyTierStorage(baseDirectory: directory))

    store.configs = [config]
    store.selectedConfigID = config.instance_id

    await store.runSelectedConfig()
    #expect(store.selectedRuntimeReadinessPhase == .starting)

    await store.toggleSelectedConfigConnection()

    #expect(client.runConfigs.map(\.instance_id) == [config.instance_id])
    #expect(client.stoppedInstanceNames == [[config.network_name]])
    #expect(!store.selectedConfigCanStop)
    #expect(!store.selectedConfigIsRunning)
    #expect(store.selectedRuntimeReadinessPhase == .stopped)
}

@MainActor
@Test func newerRuntimeRefreshWinsWhenOlderRefreshCompletesLast() async {
    let client = ControlledRuntimeRefreshClient()
    let config = NetworkConfig(instance_id: "refresh-id", network_name: "refresh-network")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = EasyTierAppStore(client: client, storage: EasyTierStorage(baseDirectory: directory))
    store.configs = [config]
    store.selectedConfigID = config.instance_id

    let olderRefresh = Task { await store.refreshRuntime() }
    await client.waitForRequest(0)
    let newerRefresh = Task { await store.refreshRuntime() }
    await client.waitForRequest(1)

    let readyDetail = NetworkInstanceRunningInfo(
        my_node_info: NodeInfo(ipv4_addr: "10.0.64.1/24", hostname: "local", peer_id: 7),
        running: true,
        instance_id: config.instance_id
    )
    await client.resolveRequest(1, with: [config.network_name: readyDetail])
    await newerRefresh.value
    await client.resolveRequest(0, with: [:])
    await olderRefresh.value

    #expect(store.selectedRuntimeReadinessPhase == .ready)
    #expect(store.selectedConfigCanStop)
    #expect(store.selectedRuntimeDetail == readyDetail)
}

@MainActor
@Test func completedRuntimeRefreshCanPublishWhileNewerRefreshIsStillInFlight() async {
    let client = ControlledRuntimeRefreshClient()
    let config = NetworkConfig(instance_id: "completion-id", network_name: "completion-network")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = EasyTierAppStore(client: client, storage: EasyTierStorage(baseDirectory: directory))
    store.configs = [config]
    store.selectedConfigID = config.instance_id

    let firstRefresh = Task { await store.refreshRuntime() }
    await client.waitForRequest(0)
    let secondRefresh = Task { await store.refreshRuntime() }
    await client.waitForRequest(1)

    let readyDetail = NetworkInstanceRunningInfo(
        my_node_info: NodeInfo(ipv4_addr: "10.0.64.1/24", hostname: "local", peer_id: 7),
        running: true,
        instance_id: config.instance_id
    )
    await client.resolveRequest(0, with: [config.network_name: readyDetail])
    await firstRefresh.value

    #expect(store.selectedRuntimeReadinessPhase == .ready)

    await client.resolveRequest(1, with: [config.network_name: readyDetail])
    await secondRefresh.value
    #expect(store.selectedRuntimeReadinessPhase == .ready)
}

@MainActor
@Test func staleRuntimeRefreshDoesNotClearNewPendingStart() async throws {
    let client = RecordingToggleClient()
    let controller = RuntimeSessionController(
        privilegedClient: client,
        inProcessClient: client,
        helperRegistration: nil,
        systemSleepPreventer: RecordingSystemSleepPreventer()
    )
    let config = NetworkConfig(instance_id: "pending-generation-id", network_name: "pending-generation-network")
    controller.recordPendingStart(for: config)
    client.networkInfos = [
        config.network_name: NetworkInstanceRunningInfo(
            my_node_info: NodeInfo(ipv4_addr: "10.0.64.1/24", hostname: "stale", peer_id: 7),
            running: true,
            instance_id: config.instance_id
        ),
    ]

    let staleChange = try await controller.refreshRuntime(
        currentInstances: [],
        currentRuntimeDetails: [:],
        currentStatusMetrics: [:],
        currentTrafficSamples: [:],
        currentTrafficSamplingStatus: [:],
        selectedTab: .status,
        shouldApply: { false }
    )
    #expect(staleChange == nil)

    client.networkInfos = [:]
    let currentResult = try await controller.refreshRuntime(
        currentInstances: [],
        currentRuntimeDetails: [:],
        currentStatusMetrics: [:],
        currentTrafficSamples: [:],
        currentTrafficSamplingStatus: [:],
        selectedTab: .status
    )
    let currentChange = try #require(currentResult)

    #expect(currentChange.state.instances.map(\.instance_id) == [config.instance_id])
    #expect(currentChange.state.instances.first?.runtimeReadinessPhase(requiresTUN: true) == .starting)
}

@MainActor
@Test func noTunRuntimeClearsPendingWithoutWaitingForVirtualIPv4() async throws {
    let client = RecordingToggleClient()
    let controller = RuntimeSessionController(
        privilegedClient: client,
        inProcessClient: client,
        helperRegistration: nil,
        systemSleepPreventer: RecordingSystemSleepPreventer()
    )
    let config = NetworkConfig(
        instance_id: "no-tun-pending-id",
        network_name: "no-tun-pending-network",
        no_tun: true
    )
    controller.recordPendingStart(for: config)
    client.networkInfos = [
        config.network_name: NetworkInstanceRunningInfo(
            my_node_info: NodeInfo(hostname: "local", peer_id: 7),
            running: true,
            instance_id: config.instance_id
        ),
    ]

    let readyResult = try await controller.refreshRuntime(
        currentInstances: [],
        currentRuntimeDetails: [:],
        currentStatusMetrics: [:],
        currentTrafficSamples: [:],
        currentTrafficSamplingStatus: [:],
        selectedTab: .status
    )
    let readyChange = try #require(readyResult)
    #expect(readyChange.state.instances.first?.runtimeReadinessPhase(requiresTUN: false) == .ready)

    client.networkInfos = [:]
    let stoppedResult = try await controller.refreshRuntime(
        currentInstances: readyChange.state.instances,
        currentRuntimeDetails: readyChange.state.runtimeDetails,
        currentStatusMetrics: readyChange.state.statusMetricsByInstance,
        currentTrafficSamples: readyChange.state.trafficSamplesByInstance,
        currentTrafficSamplingStatus: readyChange.state.trafficSamplingStatusByInstance,
        selectedTab: .status
    )
    let stoppedChange = try #require(stoppedResult)
    #expect(stoppedChange.state.instances.isEmpty)
}

@MainActor
@Test func runtimeMutationInvalidatesRefreshThatStartedBeforeFailedStop() async {
    let client = ControlledRuntimeRefreshClient()
    let config = NetworkConfig(instance_id: "generation-id", network_name: "generation-network")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = EasyTierAppStore(client: client, storage: EasyTierStorage(baseDirectory: directory))
    let readyDetail = NetworkInstanceRunningInfo(
        my_node_info: NodeInfo(ipv4_addr: "10.0.64.1/24", hostname: "local", peer_id: 7),
        running: true,
        instance_id: config.instance_id
    )
    let readyInstance = NetworkInstance(
        instance_id: config.instance_id,
        name: config.network_name,
        running: true,
        detail: readyDetail
    )
    store.configs = [config]
    store.selectedConfigID = config.instance_id
    store.instances = [readyInstance]
    store.runtimeDetails = [config.network_name: readyDetail]

    let staleRefresh = Task { await store.refreshRuntime() }
    await client.waitForRequest(0)
    await client.setStopErrorMessage("stop failed")

    let stopTask = Task { await store.stopSelectedConfig() }
    await client.waitForRequest(1)
    await client.resolveRequest(1, with: [config.network_name: readyDetail])
    await stopTask.value
    await client.resolveRequest(0, with: [:])
    await staleRefresh.value

    #expect(store.lastError?.contains("stop failed") == true)
    #expect(store.selectedRuntimeReadinessPhase == .ready)
    #expect(store.selectedRunningInstance == readyInstance)
}

@MainActor
@Test func ambientRefreshDoesNotPublishWhileStopIsInProgress() async {
    let config = NetworkConfig(instance_id: "stop-lock-id", network_name: "stop-lock-network")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let readyDetail = NetworkInstanceRunningInfo(
        my_node_info: NodeInfo(ipv4_addr: "10.0.64.1/24", hostname: "local", peer_id: 7),
        running: true,
        instance_id: config.instance_id
    )
    let client = BlockingRuntimeMutationClient(
        blocksStop: true,
        networkInfos: [config.network_name: readyDetail]
    )
    let store = EasyTierAppStore(client: client, storage: EasyTierStorage(baseDirectory: directory))
    store.configs = [config]
    store.selectedConfigID = config.instance_id
    store.instances = [NetworkInstance(
        instance_id: config.instance_id,
        name: config.network_name,
        running: true,
        detail: readyDetail
    )]
    store.runtimeDetails = [config.network_name: readyDetail]

    let stopTask = Task { await store.stopSelectedConfig() }
    await client.waitForStopRequest()
    await store.refreshRuntime()

    let countsWhileStopping = await client.counts()
    #expect(countsWhileStopping.collects == 0)
    #expect(store.selectedRuntimeReadinessPhase == .ready)

    await client.failStop(message: "stop failed")
    await stopTask.value

    #expect(store.lastError?.contains("stop failed") == true)
    #expect(store.selectedRuntimeReadinessPhase == .ready)
}

@MainActor
@Test func restartRunFailureAfterSuccessfulStopPublishesStoppedState() async {
    let client = RecordingToggleClient()
    client.runError = EasyTierCoreError.operationFailed("restart run failed")
    let config = NetworkConfig(instance_id: "restart-failure-id", network_name: "restart-failure-network")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = EasyTierAppStore(client: client, storage: EasyTierStorage(baseDirectory: directory))
    let readyDetail = NetworkInstanceRunningInfo(
        my_node_info: NodeInfo(ipv4_addr: "10.0.64.1/24", hostname: "local", peer_id: 7),
        running: true,
        instance_id: config.instance_id
    )
    let readyInstance = NetworkInstance(
        instance_id: config.instance_id,
        name: config.network_name,
        running: true,
        detail: readyDetail
    )
    store.configs = [config]
    store.selectedConfigID = config.instance_id
    store.instances = [readyInstance]
    store.runtimeDetails = [config.network_name: readyDetail]

    await store.restartSelectedConfig(replacing: readyInstance)

    #expect(client.stoppedInstanceNames == [[config.network_name]])
    #expect(client.runConfigs.map(\.instance_id) == [config.instance_id])
    #expect(store.lastError?.contains("restart run failed") == true)
    #expect(!store.selectedConfigCanStop)
    #expect(store.selectedRuntimeReadinessPhase == .stopped)
}

@MainActor
@Test func quitWaitsForInFlightRunThenStopsTheStartedRuntime() async {
    let client = BlockingRuntimeMutationClient(blocksRun: true)
    let config = NetworkConfig(instance_id: "quit-lock-id", network_name: "quit-lock-network")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = EasyTierAppStore(client: client, storage: EasyTierStorage(baseDirectory: directory))
    store.configs = [config]
    store.selectedConfigID = config.instance_id

    let runTask = Task { await store.runSelectedConfig() }
    await client.waitForRunRequest()
    let quitTask = Task { await store.prepareForAppQuit() }
    for _ in 0..<10 { await Task.yield() }
    let countsBeforeRunCompletes = await client.counts()
    #expect(countsBeforeRunCompletes.retains == 0)

    await client.resumeRun()
    _ = await runTask.value
    await quitTask.value

    let counts = await client.counts()
    #expect(counts.runs == 1)
    #expect(counts.retains == 1)
    #expect(store.isQuitting)
    #expect(store.selectedRuntimeReadinessPhase == .stopped)
}

@MainActor
@Test func queuedConnectionToggleReevaluatesStateAfterInFlightRun() async {
    let client = BlockingRuntimeMutationClient(blocksRun: true)
    let config = NetworkConfig(instance_id: "toggle-lock-id", network_name: "toggle-lock-network")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = EasyTierAppStore(client: client, storage: EasyTierStorage(baseDirectory: directory))
    store.configs = [config]
    store.selectedConfigID = config.instance_id

    let firstToggle = Task { await store.toggleSelectedConfigConnection() }
    await client.waitForRunRequest()
    let secondToggle = Task { await store.toggleSelectedConfigConnection() }
    await client.resumeRun()
    await firstToggle.value
    await secondToggle.value

    let counts = await client.counts()
    #expect(counts.runs == 1)
    #expect(counts.stops == 1)
    #expect(store.selectedRuntimeReadinessPhase == .stopped)
}

@MainActor
@Test func userStopDuringWakeRefreshCancelsAutomaticRecovery() async {
    let client = ControlledRuntimeRefreshClient()
    let config = NetworkConfig(instance_id: "wake-cancel-id", network_name: "wake-cancel-network")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = EasyTierAppStore(client: client, storage: EasyTierStorage(baseDirectory: directory))
    let readyDetail = NetworkInstanceRunningInfo(
        my_node_info: NodeInfo(ipv4_addr: "10.0.64.1/24", hostname: "local", peer_id: 7),
        running: true,
        instance_id: config.instance_id
    )
    let readyInstance = NetworkInstance(
        instance_id: config.instance_id,
        name: config.network_name,
        running: true,
        detail: readyDetail
    )
    store.configs = [config]
    store.selectedConfigID = config.instance_id
    store.instances = [readyInstance]
    store.runtimeDetails = [config.network_name: readyDetail]

    let sleepDate = Date(timeIntervalSince1970: 10_000)
    store.handleSystemWillSleep(now: sleepDate)
    let wakeTask = Task { await store.handleSystemDidWake(now: sleepDate.addingTimeInterval(31)) }
    await client.waitForRequest(0)

    let stopTask = Task { await store.stopSelectedConfig() }
    await client.waitForRequest(1)
    await client.resolveRequest(1, with: [:])
    await stopTask.value
    await client.resolveRequest(0, with: [config.network_name: readyDetail])
    await wakeTask.value

    let counts = await client.operationCounts()
    #expect(counts.runs == 0)
    #expect(counts.stops == 1)
    #expect(store.selectedRuntimeReadinessPhase == .stopped)
}

@MainActor
@Test func userStopAfterSleepBeginsCancelsAutomaticRecovery() async {
    let client = RecordingToggleClient()
    let config = NetworkConfig(instance_id: "sleep-generation-id", network_name: "sleep-generation-network")
    let readyDetail = NetworkInstanceRunningInfo(
        my_node_info: NodeInfo(ipv4_addr: "10.0.64.1/24", hostname: "local", peer_id: 7),
        running: true,
        instance_id: config.instance_id
    )
    let store = EasyTierAppStore(client: client)
    store.configs = [config]
    store.selectedConfigID = config.instance_id
    store.instances = [
        NetworkInstance(
            instance_id: config.instance_id,
            name: config.network_name,
            running: true,
            detail: readyDetail
        ),
    ]
    store.runtimeDetails = [config.network_name: readyDetail]
    client.networkInfos = [config.network_name: readyDetail]

    let sleepDate = Date(timeIntervalSince1970: 15_000)
    store.handleSystemWillSleep(now: sleepDate)
    client.networkInfos = [:]
    await store.stopSelectedConfig()
    await store.handleSystemDidWake(now: sleepDate.addingTimeInterval(31))

    #expect(client.stoppedInstanceNames == [[config.network_name]])
    #expect(client.runConfigs.isEmpty)
    #expect(store.selectedRuntimeReadinessPhase == .stopped)
}

@MainActor
@Test func stopInProgressWhenSleepBeginsIsNotAutomaticallyReversedAfterWake() async {
    let config = NetworkConfig(instance_id: "sleep-stop-id", network_name: "sleep-stop-network")
    let readyDetail = NetworkInstanceRunningInfo(
        my_node_info: NodeInfo(ipv4_addr: "10.0.64.1/24", hostname: "local", peer_id: 7),
        running: true,
        instance_id: config.instance_id
    )
    let client = BlockingRuntimeMutationClient(
        blocksStop: true,
        networkInfos: [config.network_name: readyDetail]
    )
    let store = EasyTierAppStore(client: client)
    store.configs = [config]
    store.selectedConfigID = config.instance_id
    store.instances = [
        NetworkInstance(
            instance_id: config.instance_id,
            name: config.network_name,
            running: true,
            detail: readyDetail
        ),
    ]
    store.runtimeDetails = [config.network_name: readyDetail]

    let stopTask = Task { await store.stopSelectedConfig() }
    await client.waitForStopRequest()
    let sleepDate = Date(timeIntervalSince1970: 20_000)
    store.handleSystemWillSleep(now: sleepDate)
    await client.setNetworkInfos([:])
    await client.resumeStop()
    await stopTask.value

    await store.handleSystemDidWake(now: sleepDate.addingTimeInterval(31))

    let counts = await client.counts()
    #expect(counts.runs == 0)
    #expect(counts.stops == 1)
    #expect(store.selectedRuntimeReadinessPhase == .stopped)
}

@Test func runtimeTrafficSnapshotPrecomputesDisplaySamples() throws {
    let config = NetworkConfig(instance_id: "traffic-id", network_name: "traffic-network")
    let instance = NetworkInstance(instance_id: config.instance_id, name: config.network_name, running: true)
    let base = Date(timeIntervalSince1970: 1_000)
    let windowEnd = base.addingTimeInterval(60)
    let activeSessionID = UUID()
    let previousSessionID = UUID()
    let outsideWindow = TrafficSample(
        timestamp: base.addingTimeInterval(-1),
        txBytesPerSecond: 80,
        rxBytesPerSecond: 20,
        sessionID: previousSessionID
    )
    let activeLatest = TrafficSample(
        timestamp: base.addingTimeInterval(30),
        txBytesPerSecond: 90,
        rxBytesPerSecond: 40,
        sessionID: activeSessionID
    )
    let newerPreviousSession = TrafficSample(
        timestamp: base.addingTimeInterval(40),
        txBytesPerSecond: 100,
        rxBytesPerSecond: 30,
        sessionID: previousSessionID
    )
    let invalid = TrafficSample(
        timestamp: base.addingTimeInterval(50),
        txBytesPerSecond: .nan,
        rxBytesPerSecond: 50,
        sessionID: activeSessionID
    )
    let resumeEvent = TrafficResumeEvent(
        timestamp: base.addingTimeInterval(20),
        gapDuration: 10,
        reason: .gap
    )
    let samplingStatus = RuntimeTrafficSamplingStatus(
        activeSessionID: activeSessionID,
        phase: .live,
        resumeEvent: resumeEvent,
        lastObservedAt: windowEnd
    )

    let snapshot = RuntimeTrafficSnapshot.build(
        selectedConfig: config,
        runningInstance: instance,
        samples: [newerPreviousSession, invalid, outsideWindow, activeLatest],
        samplingStatus: samplingStatus
    )

    #expect(snapshot.networkName == config.network_name)
    #expect(snapshot.samples.count == 4)
    #expect(snapshot.displaySamples.map(\.id) == [activeLatest.id, newerPreviousSession.id])
    #expect(snapshot.latest?.id == activeLatest.id)
    #expect(snapshot.maxValue == 200)
    #expect(snapshot.timeSpanLabel == "Live - Last 60 sec")
    #expect(snapshot.samplingPhase == .live)
    #expect(snapshot.activeSessionID == activeSessionID)
    #expect(snapshot.resumeEvent == resumeEvent)
    #expect(snapshot.windowStart == base)
    #expect(snapshot.windowEnd == windowEnd)
    #expect(snapshot.accessibilitySummary.contains("Upload"))
    #expect(snapshot.accessibilitySummary.contains("Download"))
}

@Test func collectingTrafficSnapshotDoesNotExposeAnOldSessionAsLatest() {
    let config = NetworkConfig(instance_id: "traffic-id", network_name: "traffic-network")
    let instance = NetworkInstance(instance_id: config.instance_id, name: config.network_name, running: true)
    let now = Date(timeIntervalSince1970: 2_000)
    let activeSessionID = UUID()
    let oldSample = TrafficSample(
        timestamp: now.addingTimeInterval(-5),
        txBytesPerSecond: 1_024,
        rxBytesPerSecond: 2_048,
        sessionID: UUID()
    )
    let resumeEvent = TrafficResumeEvent(timestamp: now, gapDuration: 86_400, reason: .gap)
    let samplingStatus = RuntimeTrafficSamplingStatus(
        activeSessionID: activeSessionID,
        phase: .collecting,
        resumeEvent: resumeEvent,
        lastObservedAt: now
    )

    let snapshot = RuntimeTrafficSnapshot.build(
        selectedConfig: config,
        runningInstance: instance,
        samples: [oldSample],
        samplingStatus: samplingStatus
    )

    #expect(snapshot.displaySamples.map(\.id) == [oldSample.id])
    #expect(snapshot.latest == nil)
    #expect(snapshot.samplingPhase == .collecting)
    #expect(snapshot.activeSessionID == activeSessionID)
    #expect(snapshot.resumeEvent == resumeEvent)
    #expect(snapshot.windowStart == now.addingTimeInterval(-60))
    #expect(snapshot.windowEnd == now)
    #expect(snapshot.timeSpanLabel == "Resuming after 1d pause...")
    #expect(snapshot.accessibilitySummary.contains("1 day"))
}

@Test func emptyRuntimeTrafficSnapshotWaitsWithoutAChartWindow() {
    #expect(RuntimeTrafficSnapshot.empty.samplingPhase == .waiting)
    #expect(RuntimeTrafficSnapshot.empty.activeSessionID == nil)
    #expect(RuntimeTrafficSnapshot.empty.windowStart == nil)
    #expect(RuntimeTrafficSnapshot.empty.windowEnd == nil)
    #expect(RuntimeTrafficSnapshot.empty.latest == nil)
}

@Test func runtimeStatusSnapshotKeepsTUNRuntimeStartingUntilVirtualIPv4Appears() {
    let config = NetworkConfig(instance_id: "dhcp-id", network_name: "dhcp-network")
    let startingDetail = NetworkInstanceRunningInfo(
        my_node_info: NodeInfo(hostname: "local", peer_id: 7),
        running: true,
        instance_id: config.instance_id
    )
    let instance = NetworkInstance(
        instance_id: config.instance_id,
        name: config.network_name,
        running: true,
        detail: startingDetail
    )

    let starting = RuntimeStatusSnapshot.build(
        selectedConfig: config,
        runningInstance: instance,
        runtimeDetail: startingDetail,
        memberStatusMetricsByID: nil
    )

    #expect(instance.isFullyConnected)
    #expect(starting.runtimeReadinessPhase == .starting)
    #expect(!starting.isFullyConnected)

    let readyDetail = NetworkInstanceRunningInfo(
        my_node_info: NodeInfo(
            virtual_ipv4: IPv4InetValue(rawValue: "10.0.64.1/24"),
            hostname: "local",
            peer_id: 7
        ),
        running: true,
        instance_id: config.instance_id
    )
    let ready = RuntimeStatusSnapshot.build(
        selectedConfig: config,
        runningInstance: instance,
        runtimeDetail: readyDetail,
        memberStatusMetricsByID: nil
    )

    #expect(ready.runtimeReadinessPhase == .ready)
    #expect(ready.isFullyConnected)
}

@Test func runtimeStatusSnapshotShowsAvailableTopologyWhileStaticTUNIsStarting() {
    let config = NetworkConfig(
        instance_id: "static-starting-id",
        dhcp: false,
        virtual_ipv4: "10.0.64.7",
        network_length: 24,
        network_name: "static-starting-network"
    )
    let detail = NetworkInstanceRunningInfo(
        my_node_info: NodeInfo(hostname: "local", peer_id: 7),
        peer_route_pairs: [
            PeerRoutePair(
                route: Route(
                    peer_id: 8,
                    ipv4_addr: IPv4InetValue(rawValue: "10.0.64.8/24"),
                    cost: 1,
                    hostname: "peer"
                ),
                peer: PeerInfo(
                    peer_id: 8,
                    conns: [
                        PeerConnInfo(
                            conn_id: "peer-connection",
                            peer_id: 8,
                            tunnel: TunnelInfo(tunnel_type: "tcp")
                        ),
                    ]
                )
            ),
        ],
        running: true,
        instance_id: config.instance_id
    )
    let instance = NetworkInstance(
        instance_id: config.instance_id,
        name: config.network_name,
        running: true,
        detail: detail
    )

    let snapshot = RuntimeStatusSnapshot.build(
        selectedConfig: config,
        runningInstance: instance,
        runtimeDetail: nil,
        memberStatusMetricsByID: nil
    )

    #expect(snapshot.runtimeReadinessPhase == .starting)
    #expect(snapshot.members.map(\.hostname) == ["local", "peer"])
    #expect(snapshot.members.first(where: \.isLocal)?.virtualIPv4 == "10.0.64.7/24")
}

@Test func runtimeStatusSnapshotDoesNotPresentConfiguredStaticIPv4AfterRuntimeFailure() throws {
    let config = NetworkConfig(
        instance_id: "failed-static-id",
        dhcp: false,
        virtual_ipv4: "10.0.64.7",
        network_length: 24,
        network_name: "failed-static-network"
    )
    let detail = NetworkInstanceRunningInfo(
        my_node_info: NodeInfo(hostname: "local", peer_id: 7),
        running: false,
        instance_id: config.instance_id
    )
    let instance = NetworkInstance(
        instance_id: config.instance_id,
        name: config.network_name,
        running: true,
        detail: detail
    )

    let snapshot = RuntimeStatusSnapshot.build(
        selectedConfig: config,
        runningInstance: instance,
        runtimeDetail: detail,
        memberStatusMetricsByID: nil
    )

    #expect(snapshot.runtimeReadinessPhase == .failed)
    let localMember = try #require(snapshot.members.first { $0.isLocal })
    #expect(localMember.copyableIPv4Address == nil)
}

@Test func runtimeStatusSnapshotTreatsNoTunRuntimeAsReadyWithoutVirtualIPv4() {
    let config = NetworkConfig(
        instance_id: "no-tun-id",
        network_name: "no-tun-network",
        no_tun: true
    )
    let detail = NetworkInstanceRunningInfo(
        my_node_info: NodeInfo(hostname: "local", peer_id: 7),
        running: true,
        instance_id: config.instance_id
    )
    let instance = NetworkInstance(
        instance_id: config.instance_id,
        name: config.network_name,
        running: true,
        detail: detail
    )

    let snapshot = RuntimeStatusSnapshot.build(
        selectedConfig: config,
        runningInstance: instance,
        runtimeDetail: detail,
        memberStatusMetricsByID: nil
    )

    #expect(snapshot.runtimeReadinessPhase == .ready)
    #expect(snapshot.isFullyConnected)
}

@Test func runtimeStatusSnapshotReportsRuntimeFailureBeforeReadiness() {
    let config = NetworkConfig(instance_id: "failed-id", network_name: "failed-network")
    let detail = NetworkInstanceRunningInfo(
        events: [
            #"{"event":{"TunDeviceError":"permission denied"}}"#,
            #"{"event":{"TunDeviceReady":"utun8"}}"#,
        ],
        running: true,
        instance_id: config.instance_id
    )
    let instance = NetworkInstance(
        instance_id: config.instance_id,
        name: config.network_name,
        running: true,
        detail: detail
    )

    let snapshot = RuntimeStatusSnapshot.build(
        selectedConfig: config,
        runningInstance: instance,
        runtimeDetail: detail,
        memberStatusMetricsByID: nil
    )

    #expect(snapshot.runtimeReadinessPhase == .failed)
    #expect(snapshot.runtimeError == "TUN device error: permission denied")
    #expect(!snapshot.isFullyConnected)

    let haltedDetail = NetworkInstanceRunningInfo(
        my_node_info: NodeInfo(ipv4_addr: "10.0.64.1/24", hostname: "local", peer_id: 7),
        running: false,
        instance_id: config.instance_id
    )
    let halted = RuntimeStatusSnapshot.build(
        selectedConfig: config,
        runningInstance: instance,
        runtimeDetail: haltedDetail,
        memberStatusMetricsByID: nil
    )

    #expect(halted.runtimeReadinessPhase == .failed)
    #expect(halted.runtimeError == "EasyTier reported that this network stopped unexpectedly.")
    #expect(!halted.isFullyConnected)
}

@Test func runtimeStatusSnapshotIgnoresTunFailureSupersededByReadyEvent() {
    let config = NetworkConfig(instance_id: "recovered-tun-id", network_name: "recovered-tun-network")
    let detail = NetworkInstanceRunningInfo(
        my_node_info: NodeInfo(ipv4_addr: "10.0.64.1/24", hostname: "local", peer_id: 7),
        events: [
            #"{"event":{"TunDeviceReady":"utun8"}}"#,
            #"{"event":{"TunDeviceError":"temporary failure"}}"#,
        ],
        running: true,
        instance_id: config.instance_id
    )
    let instance = NetworkInstance(
        instance_id: config.instance_id,
        name: config.network_name,
        running: true,
        detail: detail
    )

    let snapshot = RuntimeStatusSnapshot.build(
        selectedConfig: config,
        runningInstance: instance,
        runtimeDetail: detail,
        memberStatusMetricsByID: nil
    )

    #expect(snapshot.runtimeReadinessPhase == .ready)
    #expect(snapshot.runtimeError == nil)
}

@Test func runtimeStatusSnapshotIgnoresListenerFailureSupersededByAddedEvent() {
    let config = NetworkConfig(
        instance_id: "recovered-listener-id",
        network_name: "recovered-listener-network",
        no_tun: true
    )
    let detail = NetworkInstanceRunningInfo(
        my_node_info: NodeInfo(hostname: "local", peer_id: 7),
        events: [
            #"{"event":{"ListenerAdded":"tcp://0.0.0.0:54321"}}"#,
            #"{"event":{"ListenerAddFailed":["tcp://0.0.0.0:0","address in use"]}}"#,
        ],
        running: true,
        instance_id: config.instance_id
    )
    let instance = NetworkInstance(
        instance_id: config.instance_id,
        name: config.network_name,
        running: true,
        detail: detail
    )

    let snapshot = RuntimeStatusSnapshot.build(
        selectedConfig: config,
        runningInstance: instance,
        runtimeDetail: detail,
        memberStatusMetricsByID: nil
    )

    #expect(snapshot.runtimeReadinessPhase == .ready)
    #expect(snapshot.runtimeError == nil)
}

@MainActor
@Test func runSelectedConfigRemainsStartingUntilTUNAddressAppears() async {
    let client = RecordingToggleClient()
    let config = NetworkConfig(instance_id: "dhcp-id", network_name: "dhcp-network")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = EasyTierAppStore(client: client, storage: EasyTierStorage(baseDirectory: directory))

    store.configs = [config]
    store.selectedConfigID = config.instance_id
    client.networkInfos = [
        config.network_name: NetworkInstanceRunningInfo(
            my_node_info: NodeInfo(hostname: "local", peer_id: 7),
            running: true,
            instance_id: config.instance_id
        ),
    ]

    await store.runSelectedConfig()

    #expect(store.selectedConfigCanStop)
    #expect(store.selectedConfigIsRunning)
    #expect(!store.selectedConfigIsReady)
    #expect(store.selectedRuntimeReadinessPhase == .starting)

    client.networkInfos = [
        config.network_name: NetworkInstanceRunningInfo(
            my_node_info: NodeInfo(ipv4_addr: "10.0.64.1/24", hostname: "local", peer_id: 7),
            running: true,
            instance_id: config.instance_id
        ),
    ]
    await store.refreshRuntime()

    #expect(store.selectedConfigIsReady)
    #expect(store.selectedRuntimeReadinessPhase == .ready)
}

@MainActor
@Test func pauseThenRunRetainsMembersAndReplacesThemIncrementally() async throws {
    let client = RecordingToggleClient()
    let config = NetworkConfig(instance_id: "restart-id", network_name: "restart-network")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = EasyTierAppStore(client: client, storage: EasyTierStorage(baseDirectory: directory))
    let fullDetail = NetworkInstanceRunningInfo(
        dev_name: "utun-restart",
        my_node_info: NodeInfo(
            virtual_ipv4: IPv4InetValue(rawValue: "10.0.64.1/24"),
            hostname: "local",
            peer_id: 7
        ),
        peer_route_pairs: [
            PeerRoutePair(
                route: Route(
                    peer_id: 8,
                    ipv4_addr: IPv4InetValue(rawValue: "10.0.64.8/24"),
                    cost: 1,
                    hostname: "peer",
                    inst_id: "remote-instance"
                ),
                peer: PeerInfo(
                    peer_id: 8,
                    conns: [
                        PeerConnInfo(
                            conn_id: "remote-connection",
                            peer_id: 8,
                            tunnel: TunnelInfo(tunnel_type: "tcp")
                        ),
                    ]
                )
            ),
        ],
        running: true,
        instance_id: config.instance_id
    )

    store.configs = [config]
    store.selectedConfigID = config.instance_id
    client.networkInfos = [config.network_name: fullDetail]

    await store.runSelectedConfig()

    #expect(store.selectedRuntimeReadinessPhase == .ready)
    #expect(store.selectedMemberStatuses.map(\.hostname) == ["local", "peer"])
    #expect(store.selectedMemberStatuses.allSatisfy { $0.isLive })

    client.networkInfos = [:]
    await store.stopSelectedConfig()

    #expect(store.selectedRuntimeReadinessPhase == .stopped)
    #expect(store.selectedMemberStatuses.isEmpty)

    await store.runSelectedConfig()

    #expect(store.selectedRuntimeReadinessPhase == .starting)
    #expect(store.selectedMemberStatuses.map(\.hostname) == ["local", "peer"])
    #expect(store.selectedMemberStatuses.first(where: { $0.isLocal })?.availability == .assigningAddress)
    #expect(store.selectedMemberStatuses.first(where: { !$0.isLocal })?.availability == .connecting)

    client.networkInfos = [
        config.network_name: NetworkInstanceRunningInfo(
            dev_name: "utun-restart",
            my_node_info: NodeInfo(hostname: "local", peer_id: 7),
            running: true,
            instance_id: config.instance_id
        ),
    ]
    await store.refreshRuntime()

    #expect(store.selectedMemberStatuses.count == 2)
    #expect(store.selectedMemberStatuses.first(where: { $0.isLocal })?.availability == .assigningAddress)
    #expect(store.selectedMemberStatuses.first(where: { !$0.isLocal })?.availability == .connecting)

    client.networkInfos = [config.network_name: fullDetail]
    await store.refreshRuntime()

    #expect(store.selectedRuntimeReadinessPhase == .ready)
    #expect(store.selectedMemberStatuses.map(\.hostname) == ["local", "peer"])
    #expect(store.selectedMemberStatuses.allSatisfy { $0.isLive })
}

@Test func runtimeStatusSnapshotAppliesMemberTrafficMetrics() throws {
    let config = NetworkConfig(instance_id: "status-id", network_name: "status-network")
    let detail = NetworkInstanceRunningInfo(
        dev_name: "utun9",
        my_node_info: NodeInfo(ipv4_addr: "10.0.0.1", hostname: "local-host", peer_id: 7),
        running: true,
        instance_id: config.instance_id
    )
    let instance = NetworkInstance(instance_id: config.instance_id, name: config.network_name, running: true, detail: detail)
    let member = try #require(detail.memberStatuses.first)
    var trafficMember = member
    trafficMember.txBytes = 2_048
    trafficMember.rxBytes = 4_096

    let snapshot = RuntimeStatusSnapshot.build(
        selectedConfig: config,
        runningInstance: instance,
        runtimeDetail: detail,
        memberStatusMetricsByID: [member.id: RuntimeMemberStatusMetricsSnapshot(trafficMember)]
    )

    let displayedMember = try #require(snapshot.members.first)
    #expect(snapshot.networkName == config.network_name)
    #expect(snapshot.deviceName == "utun9")
    #expect(snapshot.isFullyConnected)
    #expect(displayedMember.txBytes == 2_048)
    #expect(displayedMember.rxBytes == 4_096)
    #expect(displayedMember.uploadTotal == ByteFormatter.format(2_048))
    #expect(displayedMember.downloadTotal == ByteFormatter.format(4_096))
}

@Test func runtimeStatusSnapshotAppliesMemberLatencyMetrics() throws {
    let config = NetworkConfig(instance_id: "status-id", network_name: "status-network")
    let detail = NetworkInstanceRunningInfo(
        dev_name: "utun9",
        peer_route_pairs: [
            PeerRoutePair(
                route: Route(
                    peer_id: 9,
                    ipv4_addr: IPv4InetValue(rawValue: "10.0.0.9/24"),
                    hostname: "remote"
                ),
                peer: PeerInfo(
                    peer_id: 9,
                    conns: [
                        PeerConnInfo(
                            peer_id: 9,
                            stats: PeerConnStats(latency_us: 1_000)
                        ),
                    ]
                )
            ),
        ],
        running: true,
        instance_id: config.instance_id
    )
    let instance = NetworkInstance(instance_id: config.instance_id, name: config.network_name, running: true, detail: detail)
    let member = try #require(detail.memberStatuses.first)
    var metricMember = member
    metricMember.latency = "8 ms"

    let snapshot = RuntimeStatusSnapshot.build(
        selectedConfig: config,
        runningInstance: instance,
        runtimeDetail: detail,
        memberStatusMetricsByID: [member.id: RuntimeMemberStatusMetricsSnapshot(metricMember)]
    )

    let displayedMember = try #require(snapshot.members.first(where: { $0.id == member.id }))
    #expect(displayedMember.latency == "8 ms")
}

@MainActor
@Test func appStoreSelectedRuntimeSnapshotsFollowSelectedConfig() throws {
    let first = NetworkConfig(instance_id: "first-id", network_name: "first-network")
    let second = NetworkConfig(instance_id: "second-id", network_name: "second-network")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = EasyTierAppStore(client: RecordingToggleClient(), storage: EasyTierStorage(baseDirectory: directory))
    let firstSample = TrafficSample(timestamp: Date(timeIntervalSince1970: 1), txBytesPerSecond: 1, rxBytesPerSecond: 2)
    let secondSample = TrafficSample(timestamp: Date(timeIntervalSince1970: 2), txBytesPerSecond: 3, rxBytesPerSecond: 4)

    store.configs = [
        first,
        second,
    ]
    store.selectedConfigID = first.instance_id
    store.instances = [
        NetworkInstance(instance_id: first.instance_id, name: first.network_name, running: true),
        NetworkInstance(instance_id: second.instance_id, name: second.network_name, running: true),
    ]
    store.runtimeDetails = [
        first.network_name: NetworkInstanceRunningInfo(dev_name: "first-device", running: true, instance_id: first.instance_id),
        second.network_name: NetworkInstanceRunningInfo(dev_name: "second-device", running: true, instance_id: second.instance_id),
    ]
    store.trafficSamplesByInstance = [
        first.network_name: [firstSample],
        second.network_name: [secondSample],
    ]

    #expect(store.selectedStatusSnapshot.networkName == first.network_name)
    #expect(store.selectedStatusSnapshot.deviceName == "first-device")
    #expect(store.selectedTrafficSnapshot.samples.map(\.id) == [firstSample.id])

    store.selectedConfigID = second.instance_id

    #expect(store.selectedStatusSnapshot.networkName == second.network_name)
    #expect(store.selectedStatusSnapshot.deviceName == "second-device")
    #expect(store.selectedTrafficSnapshot.samples.map(\.id) == [secondSample.id])
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

    store.configs = [config]
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

    store.configs = [config]
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
    let secrets = MemoryNetworkSecretStore(secrets: [config.network_name: "pending-secret"])
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = EasyTierAppStore(
        privilegedClient: client,
        inProcessClient: client,
        helperRegistration: registration,
        storage: EasyTierStorage(baseDirectory: directory),
        networkSecretStore: secrets
    )

    store.configs = [config]
    store.selectedConfigID = config.instance_id

    await store.runSelectedConfig()
    #expect(client.runConfigs.isEmpty)
    #expect(store.lastErrorIsHelperPermission)
    #expect(secrets.readReasons.count == 1)

    await store.retryStartAfterHelperApproval()
    #expect(client.runConfigs.isEmpty)

    store.handleApplicationDidResignActive()
    backend.status = .enabled
    await store.retryStartAfterHelperApproval()

    #expect(client.runConfigs.map(\.instance_id) == [config.instance_id])
    #expect(client.runConfigs.first?.network_secret == "pending-secret")
    #expect(secrets.readPurposes == [.run])
    #expect(secrets.savePurposes.isEmpty)
}

@MainActor
@Test func enteredSecretSurvivesHelperApprovalThroughKeychain() async throws {
    let client = RecordingToggleClient()
    let backend = HelperRegistrationBackendSpy(status: .requiresApproval)
    let registration = HelperRegistrationService(backend: backend.backend(), refreshOnInit: false)
    let config = NetworkConfig(instance_id: "entered-secret-approval-id", network_name: "approval-network")
    let secrets = MemoryNetworkSecretStore()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = EasyTierAppStore(
        privilegedClient: client,
        inProcessClient: client,
        helperRegistration: registration,
        storage: EasyTierStorage(baseDirectory: directory),
        networkSecretStore: secrets
    )

    store.configs = [config]
    store.selectedConfigID = config.instance_id

    let outcome = await store.runSelectedConfig(
        networkSecretInput: .edited("typed-secret")
    )

    #expect(client.runConfigs.isEmpty)
    #expect(secrets.secrets[config.network_name] == "typed-secret")
    #expect(secrets.readReasons.isEmpty)
    #expect(outcome.didPersistEditedSecret)
    #expect(secrets.savePurposes == [.update])

    store.handleApplicationDidResignActive()
    backend.status = .enabled
    await store.retryStartAfterHelperApproval()

    #expect(client.runConfigs.first?.network_secret == "typed-secret")
    #expect(secrets.readPurposes.isEmpty)
    #expect(secrets.savePurposes == [.update])
}

@MainActor
@Test func olderHelperApprovalRetryDoesNotOverwriteNewerPendingConfig() throws {
    let client = RecordingToggleClient()
    let controller = RuntimeSessionController(
        privilegedClient: client,
        inProcessClient: client,
        helperRegistration: nil,
        systemSleepPreventer: RecordingSystemSleepPreventer()
    )
    let older = NetworkConfig(instance_id: "older-approval-id", network_name: "older-approval")
    let newer = NetworkConfig(instance_id: "newer-approval-id", network_name: "newer-approval")

    controller.setPendingStartAfterApproval(older)
    #expect(controller.takePendingStartAfterApproval() == older)
    controller.setPendingStartAfterApproval(newer)
    controller.restorePendingStartAfterApprovalIfEmpty(older)

    #expect(controller.takePendingStartAfterApproval() == newer)
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

@MainActor
@Test func ensureRegisteredRemovesLegacyHelperBeforeModernRegistration() async throws {
    let backend = HelperRegistrationBackendSpy(status: .notRegistered)
    backend.legacyArtifactsPresent = true
    backend.statusAfterRegister = .enabled
    let registration = HelperRegistrationService(backend: backend.backend(), refreshOnInit: false)

    try await registration.ensureRegistered()

    #expect(backend.unregisterCount == 1)
    #expect(backend.uninstallLegacyCount == 1)
    #expect(backend.registerCount == 1)
    #expect(!backend.legacyArtifactsPresent)
    #expect(registration.state == .enabled)
}

@MainActor
@Test func ensureRegisteredUsesXPCProbeWhenServiceStatusIsStillNotFound() async throws {
    let backend = HelperRegistrationBackendSpy(status: .notFound)
    backend.statusAfterRegister = .notFound
    let registration = HelperRegistrationService(backend: backend.backend(), refreshOnInit: false)

    try await registration.ensureRegistered()

    #expect(backend.registerCount == 1)
    #expect(backend.probeCount == 1)
    #expect(registration.state == .enabled)
}

@MainActor
@Test func ensureRegisteredClassifiesXPCProbeFailureUsingServiceStatus() async throws {
    let backend = HelperRegistrationBackendSpy(status: .notFound)
    backend.statusAfterRegister = .requiresApproval
    backend.probeError = PrivilegedHelperError.unavailable
    let registration = HelperRegistrationService(backend: backend.backend(), refreshOnInit: false)

    do {
        try await registration.ensureRegistered()
        Issue.record("ensureRegistered should surface the failed helper probe")
    } catch let error as PrivilegedHelperError {
        #expect(error == .needsRegistration)
    } catch {
        Issue.record("unexpected error: \(error)")
    }

    #expect(backend.probeCount == 1)
    #expect(registration.state == .requiresApproval)
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

@Test func runtimeInfoTreatsAnyReachablePublicServerAsFullyConnected() throws {
    let json = """
    {
      "my_node_info": {
        "hostname": "macbook",
        "peer_id": 100
      },
      "peer_route_pairs": [
        {
          "route": { "peer_id": 200, "hostname": "PublicServer_down", "cost": 1 },
          "peer": { "peer_id": 200, "conns": [] }
        },
        {
          "route": {
            "peer_id": 201,
            "hostname": "relay-online",
            "cost": 1,
            "feature_flag": { "is_public_server": true }
          },
          "peer": { "peer_id": 201, "conns": [ { "conn_id": "relay-online" } ] }
        },
        {
          "route": { "peer_id": 202, "hostname": "office-mini", "cost": 2 },
          "peer": { "peer_id": 202, "conns": [] }
        }
      ],
      "running": true
    }
    """

    let info = try JSONDecoder().decode(NetworkInstanceRunningInfo.self, from: Data(json.utf8))

    #expect(info.isFullyConnected)
    #expect(info.isFullyConnected(expectRemotePeers: true))
}

@Test func runtimeInfoRequiresReachablePublicServerWhenPublicServersAreKnown() throws {
    let json = """
    {
      "my_node_info": {
        "hostname": "macbook",
        "peer_id": 100
      },
      "peer_route_pairs": [
        {
          "route": { "peer_id": 200, "hostname": "PublicServer_one", "cost": 1 },
          "peer": { "peer_id": 200, "conns": [] }
        },
        {
          "route": {
            "peer_id": 201,
            "hostname": "relay-two",
            "cost": 1,
            "feature_flag": { "is_public_server": true }
          },
          "peer": { "peer_id": 201, "conns": [] }
        }
      ],
      "running": true
    }
    """

    let info = try JSONDecoder().decode(NetworkInstanceRunningInfo.self, from: Data(json.utf8))

    #expect(!info.isFullyConnected)
    #expect(!info.isFullyConnected(expectRemotePeers: true))
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
    #expect(WorkspaceTab.allCases.map(\.rawValue) == ["Status", "View", "Config", "Logs", "Peers"])
    #expect(WorkspaceTab.allCases.map(\.displayTitle) == ["Status", "Traffic", "Config", "Logs", "Peers"])
}

private func hostnameIntent(instanceID: String, networkName: String, base: String, desired: String) -> RuntimeIntent {
    RuntimeIntent(
        target: RuntimeIntentTarget(
            networkName: networkName,
            instanceID: instanceID,
            recentHostname: base,
            isLocal: true
        ),
        desiredHostname: desired,
        baseHostname: base,
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
    var savePurposes: [NetworkSecretAccessPurpose] = []
    var readPurposes: [NetworkSecretAccessPurpose] = []
    var deletePurposes: [NetworkSecretAccessPurpose] = []
    var readReasons: [String?] = []
    var readError: Error?
    var saveError: Error?
    var deleteError: Error?
    var containsError: Error?
    var saveCleanup: NetworkSecretCleanupState = .notNeeded
    var authenticationPurposes: [NetworkSecretAccessPurpose] = []
    private(set) var presenceCallCount = 0
    private(set) var authenticationInvalidationCount = 0

    init(secrets: [String: String] = [:]) {
        self.secrets = secrets
    }

    func save(
        _ secret: String,
        for config: NetworkConfig,
        purpose: NetworkSecretAccessPurpose
    ) async throws -> NetworkSecretWriteResult {
        savePurposes.append(purpose)
        if let saveError { throw saveError }
        secrets[config.network_name] = secret
        return NetworkSecretWriteResult(cleanup: saveCleanup)
    }

    func secret(
        for config: NetworkConfig,
        purpose: NetworkSecretAccessPurpose,
        reason: String?
    ) async throws -> NetworkSecretReadResult? {
        readPurposes.append(purpose)
        readReasons.append(reason)
        if let readError { throw readError }
        return secrets[config.network_name].map {
            NetworkSecretReadResult(secret: $0, cleanup: .notNeeded)
        }
    }

    func deleteSecret(
        for config: NetworkConfig,
        purpose: NetworkSecretAccessPurpose
    ) async throws {
        deletePurposes.append(purpose)
        if let deleteError { throw deleteError }
        deletedIDs.append(config.network_name)
        secrets.removeValue(forKey: config.network_name)
    }

    func presence(for config: NetworkConfig) async throws -> NetworkSecretPresence {
        presenceCallCount += 1
        if let containsError { throw containsError }
        return secrets[config.network_name] == nil ? .missing : .present
    }

    func migrateSecret(
        from oldConfig: NetworkConfig,
        to newConfig: NetworkConfig,
        removeSource: Bool
    ) async throws -> NetworkSecretWriteResult {
        if secrets[newConfig.network_name] == nil,
           let secret = secrets[oldConfig.network_name]
        {
            secrets[newConfig.network_name] = secret
        }
        if removeSource {
            secrets.removeValue(forKey: oldConfig.network_name)
        }
        return NetworkSecretWriteResult(cleanup: .notNeeded)
    }

    func authenticate(
        for _: NetworkConfig,
        purpose: NetworkSecretAccessPurpose
    ) async throws {
        authenticationPurposes.append(purpose)
    }

    func invalidateAuthenticationSession() {
        authenticationInvalidationCount += 1
    }
}

private final class BlockingNetworkSecretStore: NetworkSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private let storedSecret: String
    private var storedReadCount = 0
    private var storedDeleteCount = 0
    private var storedAuthenticationInvalidationCount = 0
    private var readContinuations: [CheckedContinuation<Void, Never>] = []
    private var deleteContinuations: [CheckedContinuation<Void, Never>] = []

    init(secret: String) {
        storedSecret = secret
    }

    var readCount: Int {
        lock.withLock { storedReadCount }
    }

    var authenticationInvalidationCount: Int {
        lock.withLock { storedAuthenticationInvalidationCount }
    }

    var deleteCount: Int {
        lock.withLock { storedDeleteCount }
    }

    func save(
        _: String,
        for _: NetworkConfig,
        purpose _: NetworkSecretAccessPurpose
    ) async throws -> NetworkSecretWriteResult {
        NetworkSecretWriteResult(cleanup: .notNeeded)
    }

    func secret(
        for _: NetworkConfig,
        purpose _: NetworkSecretAccessPurpose,
        reason _: String?
    ) async throws -> NetworkSecretReadResult? {
        await withCheckedContinuation { continuation in
            lock.withLock {
                storedReadCount += 1
                readContinuations.append(continuation)
            }
        }
        return NetworkSecretReadResult(secret: storedSecret, cleanup: .notNeeded)
    }

    func deleteSecret(
        for _: NetworkConfig,
        purpose _: NetworkSecretAccessPurpose
    ) async throws {
        await withCheckedContinuation { continuation in
            lock.withLock {
                storedDeleteCount += 1
                deleteContinuations.append(continuation)
            }
        }
    }

    func presence(for _: NetworkConfig) async throws -> NetworkSecretPresence { .present }

    func migrateSecret(
        from _: NetworkConfig,
        to _: NetworkConfig,
        removeSource _: Bool
    ) async throws -> NetworkSecretWriteResult {
        NetworkSecretWriteResult(cleanup: .notNeeded)
    }

    func invalidateAuthenticationSession() {
        lock.withLock { storedAuthenticationInvalidationCount += 1 }
    }

    func releaseReads() {
        let continuations = lock.withLock {
            let continuations = readContinuations
            readContinuations.removeAll()
            return continuations
        }
        continuations.forEach { $0.resume() }
    }

    func releaseDeletes() {
        let continuations = lock.withLock {
            let continuations = deleteContinuations
            deleteContinuations.removeAll()
            return continuations
        }
        continuations.forEach { $0.resume() }
    }
}

private final class PendingStartClient: EasyTierCoreClient, @unchecked Sendable {
    var didRun = false

    func validate(toml _: String) async throws {}

    func run(toml _: String) async throws {
        didRun = true
    }

    func stop(instanceNames _: [String]) async throws {}
    func retain(instanceNames _: [String]) async throws {}
    func collectNetworkInfos() async throws -> [String: NetworkInstanceRunningInfo] { [:] }
    func configureRPCPortal(_ rpcPortal: String?, whitelist _: [String]?) async throws {
        if rpcPortal != nil { throw EasyTierCoreError.operationFailed("unsupported") }
    }

    func callJSONRPC(clientID _: String, url _: URL, service _: String, method _: String, domain _: String?, payload _: String) async throws -> String {
        throw EasyTierCoreError.operationFailed("unsupported")
    }
}

private final class RecordingToggleClient: EasyTierCoreClient, EasyTierHelperShutdownClient, @unchecked Sendable {
    var runConfigs: [NetworkConfig] = []
    var runTOMLs: [String] = []
    var stoppedInstanceNames: [[String]] = []
    var retainedInstanceNames: [[String]] = []
    var networkInfos: [String: NetworkInstanceRunningInfo] = [:]
    var configuredRPCPortals: [String?] = []
    var configuredRPCPortalWhitelists: [[String]?] = []
    var jsonRPCCalls: [EasyTierRPCRequest] = []
    var jsonRPCResponsesByMethod: [String: String] = [:]
    var shutdownCount = 0
    var runError: Error?
    var stopError: Error?
    var collectError: Error?
    var jsonRPCError: Error?

    func validate(toml _: String) async throws {}

    func run(toml: String) async throws {
        runTOMLs.append(toml)
        if let config = try? NetworkConfigTOMLCodec.decode(toml) {
            runConfigs.append(config)
        }
        if let runError { throw runError }
    }

    func stop(instanceNames: [String]) async throws {
        stoppedInstanceNames.append(instanceNames)
        if let stopError { throw stopError }
    }

    func retain(instanceNames: [String]) async throws {
        retainedInstanceNames.append(instanceNames)
    }

    func collectNetworkInfos() async throws -> [String: NetworkInstanceRunningInfo] {
        if let collectError { throw collectError }
        return networkInfos
    }
    func configureRPCPortal(_ rpcPortal: String?, whitelist: [String]?) async throws {
        configuredRPCPortals.append(rpcPortal)
        configuredRPCPortalWhitelists.append(whitelist)
    }

    func callJSONRPC(clientID _: String, url _: URL, service: String, method: String, domain: String?, payload: String) async throws -> String {
        jsonRPCCalls.append(EasyTierRPCRequest(service: service, method: method, domain: domain, payload: payload))
        if let jsonRPCError { throw jsonRPCError }
        return jsonRPCResponsesByMethod[method] ?? #"{"ok":true}"#
    }

    func shutdownHelper() async throws {
        shutdownCount += 1
    }
}

private actor ControlledRuntimeRefreshClient: EasyTierCoreClient {
    private var collectContinuations: [
        Int: CheckedContinuation<[String: NetworkInstanceRunningInfo], Error>
    ] = [:]
    private var nextRequestID = 0
    private var stopErrorMessage: String?
    private var runCount = 0
    private var stopCount = 0

    func validate(toml _: String) async throws {}
    func run(toml _: String) async throws {
        runCount += 1
    }

    func stop(instanceNames _: [String]) async throws {
        stopCount += 1
        if let stopErrorMessage { throw EasyTierCoreError.operationFailed(stopErrorMessage) }
    }

    func retain(instanceNames _: [String]) async throws {}

    func collectNetworkInfos() async throws -> [String: NetworkInstanceRunningInfo] {
        let requestID = nextRequestID
        nextRequestID += 1
        return try await withCheckedThrowingContinuation { continuation in
            collectContinuations[requestID] = continuation
        }
    }

    func configureRPCPortal(_: String?, whitelist _: [String]?) async throws {}

    func callJSONRPC(
        clientID _: String,
        url _: URL,
        service _: String,
        method _: String,
        domain _: String?,
        payload _: String
    ) async throws -> String {
        throw EasyTierCoreError.operationFailed("unsupported")
    }

    func waitForRequest(_ requestID: Int) async {
        while collectContinuations[requestID] == nil {
            await Task.yield()
        }
    }

    func resolveRequest(
        _ requestID: Int,
        with infos: [String: NetworkInstanceRunningInfo]
    ) {
        collectContinuations.removeValue(forKey: requestID)?.resume(returning: infos)
    }

    func setStopErrorMessage(_ message: String?) {
        stopErrorMessage = message
    }

    func operationCounts() -> (runs: Int, stops: Int) {
        (runCount, stopCount)
    }
}

private actor BlockingRuntimeMutationClient: EasyTierCoreClient {
    private let blocksRun: Bool
    private let blocksStop: Bool
    private var networkInfos: [String: NetworkInstanceRunningInfo]
    private var runContinuation: CheckedContinuation<Void, Error>?
    private var stopContinuation: CheckedContinuation<Void, Error>?
    private var runCount = 0
    private var stopCount = 0
    private var retainCalls: [[String]] = []
    private var collectCount = 0

    init(
        blocksRun: Bool = false,
        blocksStop: Bool = false,
        networkInfos: [String: NetworkInstanceRunningInfo] = [:]
    ) {
        self.blocksRun = blocksRun
        self.blocksStop = blocksStop
        self.networkInfos = networkInfos
    }

    func validate(toml _: String) async throws {}

    func run(toml _: String) async throws {
        runCount += 1
        guard blocksRun else { return }
        try await withCheckedThrowingContinuation { continuation in
            runContinuation = continuation
        }
    }

    func stop(instanceNames _: [String]) async throws {
        stopCount += 1
        guard blocksStop else { return }
        try await withCheckedThrowingContinuation { continuation in
            stopContinuation = continuation
        }
    }

    func retain(instanceNames: [String]) async throws {
        retainCalls.append(instanceNames)
    }

    func collectNetworkInfos() async throws -> [String: NetworkInstanceRunningInfo] {
        collectCount += 1
        return networkInfos
    }

    func configureRPCPortal(_: String?, whitelist _: [String]?) async throws {}

    func callJSONRPC(
        clientID _: String,
        url _: URL,
        service _: String,
        method _: String,
        domain _: String?,
        payload _: String
    ) async throws -> String {
        throw EasyTierCoreError.operationFailed("unsupported")
    }

    func waitForRunRequest() async {
        while runContinuation == nil {
            await Task.yield()
        }
    }

    func waitForStopRequest() async {
        while stopContinuation == nil {
            await Task.yield()
        }
    }

    func resumeRun() {
        runContinuation?.resume()
        runContinuation = nil
    }

    func failStop(message: String) {
        stopContinuation?.resume(throwing: EasyTierCoreError.operationFailed(message))
        stopContinuation = nil
    }

    func resumeStop() {
        stopContinuation?.resume()
        stopContinuation = nil
    }

    func setNetworkInfos(_ infos: [String: NetworkInstanceRunningInfo]) {
        networkInfos = infos
    }

    func counts() -> (runs: Int, stops: Int, retains: Int, collects: Int) {
        (runCount, stopCount, retainCalls.count, collectCount)
    }
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
    var statusAfterRegister: SMAppService.Status?
    var legacyArtifactsPresent = false
    var legacyInstalled = false
    var registerCount = 0
    var unregisterCount = 0
    var uninstallLegacyCount = 0
    var probeCount = 0
    var probeError: Error?

    init(status: SMAppService.Status) {
        self.status = status
    }

    func backend() -> HelperRegistrationService.Backend {
        HelperRegistrationService.Backend(
            status: {
                if self.registerCount > 0, let statusAfterRegister = self.statusAfterRegister {
                    return statusAfterRegister
                }
                return self.status
            },
            register: {
                self.registerCount += 1
                if let statusAfterRegister = self.statusAfterRegister {
                    self.status = statusAfterRegister
                }
            },
            unregister: { self.unregisterCount += 1 },
            canInstallHelper: { true },
            useLegacyInstaller: { false },
            legacyArtifactsExist: { self.legacyArtifactsPresent },
            legacyIsInstalled: { self.legacyInstalled },
            installLegacy: {},
            uninstallLegacy: {
                self.uninstallLegacyCount += 1
                self.legacyArtifactsPresent = false
                self.legacyInstalled = false
            },
            probeHelper: {
                self.probeCount += 1
                if let probeError = self.probeError {
                    throw probeError
                }
            }
        )
    }
}

private final class HelperRunErrorClient: EasyTierCoreClient, @unchecked Sendable {
    let payload: PrivilegedHelperErrorPayload

    init(payload: PrivilegedHelperErrorPayload) {
        self.payload = payload
    }

    func validate(toml _: String) async throws {}

    func run(toml _: String) async throws {
        throw PrivilegedHelperError.helperReported(payload)
    }

    func stop(instanceNames _: [String]) async throws {}
    func retain(instanceNames _: [String]) async throws {}
    func collectNetworkInfos() async throws -> [String: NetworkInstanceRunningInfo] { [:] }
    func configureRPCPortal(_: String?, whitelist _: [String]?) async throws {}
    func callJSONRPC(clientID _: String, url _: URL, service _: String, method _: String, domain _: String?, payload _: String) async throws -> String { "" }
}
