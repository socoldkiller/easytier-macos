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
